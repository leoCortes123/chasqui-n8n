#!/usr/bin/env python3
"""wf_router — entrada por Telegram. Webhook en ruta fija (el registrador lo
re-apunta al cambiar el túnel). Normaliza el update, llama a
router_procesar_mensaje y despacha respuestas[] y acciones[].

Un toque de botón llega como callback_query y se normaliza al MISMO campo
`texto` que un mensaje escrito, porque los callback_data de los teclados son los
propios comandos (ver migración 023). Así el router no distingue botón de texto
y no hay dos máquinas de estados. Lo único extra es contestarle a Telegram que
el toque se recibió, o el botón se queda con el relojito girando."""
import os
from wf_lib import WF, PG, TG

# El secreto queda EMBEBIDO en el nodo Normalizar, así que generar sin el .env
# cargado produce un workflow que compara contra '' y rechaza todos los updates
# de Telegram en silencio: el bot deja de contestar y no hay error en ninguna
# parte. Pasó. Por eso se aborta en vez de asumir un valor por defecto.
SECRET = os.environ.get("TELEGRAM_WEBHOOK_SECRET", "")
if not SECRET:
    raise SystemExit(
        "falta TELEGRAM_WEBHOOK_SECRET: corré 'set -a; . ./.env; set +a' antes "
        "de generar, o el webhook va a rechazar todo lo que llegue")
PATH   = os.environ.get("TELEGRAM_WEBHOOK_PATH", "telegram")

w = WF("wfRouter000000000001", "wf_router")

# Webhook fijo. responseMode onReceived: responde 200 de inmediato a Telegram.
w.node("Webhook", "n8n-nodes-base.webhook", 2, {
    "httpMethod": "POST", "path": PATH, "responseMode": "onReceived",
    "options": {}}, [0, 300], None,
    {"webhookId": "wfRouterWebhook00001"})

# Verifica el secreto y normaliza el update a {from,chat,texto,tiene_documento}.
w.code("Normalizar", f"""
const item = $input.first().json;
const secretOk = (item.headers?.['x-telegram-bot-api-secret-token'] || '') === {SECRET!r};
if (!secretOk) return [];              // rechaza lo que no venga de Telegram
const b = item.body || item;
const msg = b.message || b.edited_message || b.callback_query?.message || {{}};
const from = b.message?.from || b.callback_query?.from || msg.from || {{}};
const texto = b.message?.text || b.callback_query?.data || msg.caption || '';
const tiene_documento = !!(msg.document || (msg.photo && msg.photo.length));
if (!from.id) return [];
return [{{ json: {{ evento: {{
  canal: 'telegram',
  from: {{ id: from.id, username: from.username }},
  chat: {{ id: msg.chat?.id || from.id }},
  texto, tiene_documento,
  // Solo presentes cuando el update es un toque de botón. `message_id` es el
  // mensaje que TRAE el botón: es lo que permite reemplazar esa pantalla en vez
  // de apilar otra (070). Sin él, la respuesta sale como mensaje nuevo.
  callback_id: b.callback_query?.id || null,
  message_id: b.callback_query?.message?.message_id || null,
  file_id: msg.document?.file_id || (msg.photo ? msg.photo[msg.photo.length-1].file_id : null),
  file_name: msg.document?.file_name || null,
  mime: msg.document?.mime_type || null
}} }} }}];
""", [220, 300])
w.link("Webhook", "Normalizar")

w.if_("EsBoton?", "={{ !!$json.evento.callback_id }}", [400, 300])
w.link("Normalizar", "EsBoton?")

# answerCallbackQuery: Telegram deja el botón con el relojito girando hasta que
# se le contesta. Sin texto no muestra ningún aviso, solo apaga el reloj.
#
# onError acá SÍ va: un callback_id vencido (el usuario toca un botón de hace
# horas) devuelve 400 "query is too old", y eso no puede impedir que el mensaje
# se procese. Es la excepción, no la regla: lo que se pierde es un relojito, no
# una respuesta al usuario —a diferencia de EnviarTexto en wf_enviar, donde el
# mismo onError escondió durante horas que el informe no se entregaba—.
w.node("Responder", "n8n-nodes-base.telegram", 1.2, {
    "resource": "callback",
    "operation": "answerQuery",
    "queryId": "={{ $json.evento.callback_id }}",
    "additionalFields": {}}, [600, 200], {"telegramApi": TG},
    {"onError": "continueRegularOutput"})
w.link("EsBoton?", "Responder", 0)

# El evento se lee de Normalizar, no de $json: en la rama del botón el item que
# llega acá es la respuesta de Telegram al answerCallbackQuery.
# El envoltorio de la 070 le pega el message_id del botón a las respuestas cuya
# plantilla sea de navegación. Va acá y no dentro del router para no volver
# STABLE a `router_respuesta`, que usan los seis handlers: el evento entra dos
# veces a la misma consulta y ningún handler se entera.
w.pg("Router",
     "SELECT router_marcar_editables(router_procesar_mensaje(ev), ev) AS r "
     "FROM (SELECT "
     "'{{ JSON.stringify($('Normalizar').first().json.evento).replaceAll(\"'\",\"''\") }}'"
     "::jsonb AS ev) e;",
     [800, 300])
w.link("Responder", "Router")
w.link("EsBoton?", "Router", 1)

# Separa respuestas y acciones.
w.code("Despachar", """
const r = $input.first().json.r || {};
const ev = $('Normalizar').first().json.evento;
const out = [];
if ((r.respuestas||[]).length)
  out.push({ json: { tipo:'enviar', chat_id:r.chat_id, respuestas:r.respuestas } });
for (const a of (r.acciones||[])) {
  // 071: el panel de carga lo dibuja wf_enviar, que espera {panel:{...}}.
  if (a.tipo === 'panel')
    out.push({ json: { tipo:'panel', chat_id:r.chat_id,
      panel: { sesion_id: a.sesion_id, modo: a.modo || 'panel' } } });
  else
    out.push({ json: { tipo:a.tipo, chat_id:r.chat_id, ...a, evento: ev } });
}
return out;
""", [1000, 300])
w.link("Router", "Despachar")

# Ruteo por tipo de acción.
w.node("Switch", "n8n-nodes-base.switch", 3, {
  "rules": {"values": [
    {"conditions": {"options": {"typeValidation":"loose"}, "combinator":"and",
       "conditions":[{"leftValue":"={{ $json.tipo }}","rightValue":"enviar",
         "operator":{"type":"string","operation":"equals"}}]}, "outputKey":"enviar"},
    {"conditions": {"options": {"typeValidation":"loose"}, "combinator":"and",
       "conditions":[{"leftValue":"={{ $json.tipo }}","rightValue":"ingerir",
         "operator":{"type":"string","operation":"equals"}}]}, "outputKey":"ingerir"},
    {"conditions": {"options": {"typeValidation":"loose"}, "combinator":"and",
       "conditions":[{"leftValue":"={{ $json.tipo }}","rightValue":"ejecutar",
         "operator":{"type":"string","operation":"equals"}}]}, "outputKey":"ejecutar"},
    # 071: refrescar el panel de carga. Sale por el mismo wf_enviar que todo lo
    # demás; lo único que cambia es la forma del item.
    {"conditions": {"options": {"typeValidation":"loose"}, "combinator":"and",
       "conditions":[{"leftValue":"={{ $json.tipo }}","rightValue":"panel",
         "operator":{"type":"string","operation":"equals"}}]}, "outputKey":"panel"},
  ]}, "options": {}}, [1220, 300])
w.link("Despachar", "Switch")

def exec_wf(name, wid, pos, esperar=True):
    return w.node(name, "n8n-nodes-base.executeWorkflow", 1.2, {
        "workflowId": {"__rl": True, "value": wid, "mode": "id"},
        "workflowInputs": {"mappingMode":"defineBelow","value":{}},
        "options": {} if esperar else {"waitForSubWorkflow": False}},
        pos, None, {"onError":"continueRegularOutput"})

# salida 0 enviar, 1 ingerir, 2 ejecutar
exec_wf("LlamarEnviar", "wfEnviar00000000001", [1440, 180])
w.link("Switch", "LlamarEnviar", 0)

exec_wf("LlamarIngesta", "wfIngesta00000000001", [1440, 300])
w.link("Switch", "LlamarIngesta", 1)

# El análisis se dispara y se suelta: desde ahora wf_ejecutar entrega su propio
# informe. Si el router esperara, la generación entera correría dentro de SU
# ejecución y contra SU reloj de 300 segundos, que es exactamente cómo se perdió
# un informe ya terminado en la segunda prueba de usuario.
exec_wf("LlamarEjecutar", "wfEjecutar000000001", [1440, 440], esperar=False)
w.link("Switch", "LlamarEjecutar", 2)

# salida 3: panel -> el mismo wf_enviar
w.link("Switch", "LlamarEnviar", 3)

w.dump("workflows/wf_router.json")
