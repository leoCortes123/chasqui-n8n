#!/usr/bin/env python3
"""wf_enviar — único punto de salida al canal. Recibe {chat_id, respuestas[]}
y opcionalmente un binario 'documento'. Resuelve cada plantilla en Postgres y
manda por Telegram. Texto y documento en dos ramas desde el trigger.

Los botones vienen resueltos de la base: resolver_plantilla devuelve el
reply_markup ya armado (ver migración 023). Una respuesta puede traer su propio
`teclado` para pisar el de la fila —lo usa el router para la lista de servicios,
que es dinámica—.

POR QUÉ HAY UN NODO DE ENVÍO POR CANTIDAD DE FILAS
--------------------------------------------------
El nodo de Telegram de n8n no acepta un reply_markup ya armado. `getNodeParameter`
resuelve los parámetros contra la DESCRIPCIÓN del nodo y descarta todo lo que no
esté declarado ahí, así que la FORMA del teclado (cuántas filas, cuántos botones)
tiene que estar literal en el workflow; solo las hojas —el texto del botón y su
callback_data— pueden salir de una expresión.

Comprobado con cinco sondas contra la API real, mirando si Telegram devuelve
`reply_markup` en la respuesta:

  A  additionalFields.reply_markup (objeto o string)   -> se descarta
  B  inlineKeyboard entero por expresión               -> teclado vacío
  E  el array `buttons` de la fila por expresión       -> llegan los botones pero
                                                          SIN callback_data:
                                                          "Text buttons are
                                                          unallowed in the inline
                                                          keyboard"
  F  el objeto `row` por expresión                     -> teclado vacío
  D  forma literal + expresiones en las hojas          -> FUNCIONA

De ahí el diseño: `Filas` aplana el teclado a un botón por fila y el Switch elige
el nodo que tiene esa cantidad de filas literales. Lo único que queda fijo en el
workflow es el tope de filas; el contenido sigue viviendo en la base.

La alternativa limpia —un nodo HTTP Request contra api.telegram.org, con control
total del body— necesita el token del bot dentro del contenedor de n8n
(TELEGRAM_BOT_TOKEN hoy solo lo ve el servicio `registrador`), y agregarlo obliga
a recrear el contenedor. Queda pendiente de decisión.
"""
import os, sys
from wf_lib import WF, PG, TG, WA, GRAPH

# Embebido en las URLs de la Graph API al generar (mismo criterio que el secreto
# en wf_router). Sin él el workflow igual sirve: la rama WhatsApp solo corre
# para chats cuyo canal resuelto sea whatsapp, y sin credenciales no hay nadie así.
WA_PNID = os.environ.get("WA_PHONE_NUMBER_ID", "")
if not WA_PNID:
    print("aviso: WA_PHONE_NUMBER_ID vacío; la rama WhatsApp queda generada "
          "pero no funcional hasta regenerar con el .env completo", file=sys.stderr)

# Tope de filas del teclado. Cada fila lleva UN botón: en un chat, una lista
# vertical se lee mejor que una parrilla, y así el aplanado es trivial.
# Subirlo es cambiar este número y regenerar; teclado_markup en la base aplica el
# mismo tope (migración 027) para que no pueda existir un teclado que el
# enviador no sepa expresar.
MAX_FILAS = 6

w = WF("wfEnviar00000000001", "wf_enviar")

w.node("Inicio", "n8n-nodes-base.executeWorkflowTrigger", 1.1,
       {"inputSource": "passthrough"}, [0, 300])

# --- Rama texto ---------------------------------------------------------------
w.code("Expandir", """
const inp = $input.first().json;
const chat = inp.chat_id;
const out = [];
for (const r of (inp.respuestas || [])) {
  if (r.plantilla) out.push({ json: {
    chat_id: chat, plantilla: r.plantilla, vars: r.vars || {},
    // null explícito: la plantilla se queda con el teclado de su fila.
    teclado: r.teclado ?? null } });
}
return out;
""", [220, 200])
w.link("Inicio", "Expandir")

# Además de resolver la plantilla, decide el canal del chat (044) y, si es
# WhatsApp, deja armados los cuerpos para la Graph API: texto convertido de
# HTML y teclado traducido a botones/lista. Todo el formato sigue en la base.
w.pg("Resolver",
     "SELECT c.chat_id, c.canal, "
     "res ->> 'texto'  AS texto, "
     "res -> 'teclado' AS teclado, "
     "CASE WHEN c.canal = 'whatsapp' THEN "
     "wa_payload(c.chat_id::text, wa_texto(res ->> 'texto'), res -> 'teclado') "
     "END AS wa "
     "FROM resolver_plantilla('{{ $json.plantilla }}', "
     "'{{ JSON.stringify($json.vars).replaceAll(\"'\",\"''\") }}'::jsonb, "
     "'{{ JSON.stringify($json.teclado ?? null).replaceAll(\"'\",\"''\") }}'::jsonb"
     ") AS t(res), "
     "LATERAL (SELECT ({{ $json.chat_id }})::bigint AS chat_id, "
     "canal_de_chat(({{ $json.chat_id }})::bigint) AS canal) c;",
     [440, 200])
w.link("Expandir", "Resolver")

# --- Bifurcación por canal ----------------------------------------------------
w.if_("EsWa?", "={{ $json.canal === 'whatsapp' }}", [560, 340])
w.link("Resolver", "EsWa?")

# wa_payload devuelve un ARRAY de cuerpos (texto largo + botones = 2 mensajes).
w.code("PartirWa", """
const out = [];
for (const item of $input.all())
  for (const body of (item.json.wa || []))
    out.push({ json: { chat_id: item.json.chat_id, body } });
return out;
""", [720, 460])
w.link("EsWa?", "PartirWa", 0)

# HTTP Request directo a la Graph API: acá no hay la limitación del nodo de
# Telegram, el body entero sale de una expresión. Mismo criterio de errores que
# EnviarTexto: sin onError (un mensaje que no llega tiene que verse) y con retry.
w.node("EnviarWa", "n8n-nodes-base.httpRequest", 4.2, {
    "method": "POST", "url": f"{GRAPH}/{WA_PNID}/messages",
    "authentication": "genericCredentialType", "genericAuthType": "httpHeaderAuth",
    "sendBody": True, "specifyBody": "json",
    "jsonBody": "={{ JSON.stringify($json.body) }}",
    "options": {"timeout": 30000}}, [900, 460], {"httpHeaderAuth": WA},
    {"retryOnFail": True, "maxTries": 3, "waitBetweenTries": 2000})
w.link("PartirWa", "EnviarWa")

# Aplana el teclado a un botón por fila y rellena los huecos, para que las
# expresiones de los nodos de envío nunca apunten a un índice inexistente.
w.code("Filas", f"""
const j = $input.first().json;
const MAX = {MAX_FILAS};
const btns = [];
for (const fila of (j.teclado?.inline_keyboard || []))
  for (const b of (fila || []))
    if (b && b.text && b.callback_data) btns.push({{ text: b.text, dato: b.callback_data }});
const usados = btns.slice(0, MAX);
const relleno = Array.from({{ length: MAX - usados.length }}, () => ({{ text: '', dato: '' }}));
return [{{ json: {{ ...j, n: usados.length, b: usados.concat(relleno) }} }}];
""", [660, 200])
w.link("EsWa?", "Filas", 1)

w.node("CuantasFilas", "n8n-nodes-base.switch", 3, {
    "rules": {"values": [
        {"conditions": {"options": {"typeValidation": "loose"}, "combinator": "and",
            "conditions": [{"leftValue": "={{ $json.n }}", "rightValue": k,
                "operator": {"type": "number", "operation": "equals"}}]},
         "outputKey": f"filas{k}"}
        for k in range(MAX_FILAS + 1)]},
    "options": {}}, [880, 200])
w.link("Filas", "CuantasFilas")

# appendAttribution: false quita el "This message was sent automatically with
# n8n" que el nodo agrega por defecto al final de cada mensaje.
#
# parse_mode HTML explícito. No existe "sin parse_mode": el nodo fuerza Markdown
# cuando no se le pide otra cosa (GenericFunctions.js:29), y el Markdown legacy
# revienta el mensaje entero ante un guion bajo suelto —un código de servicio
# como `ventas_compras` alcanzaba—. HTML es el único modo con una regla de escape
# simple, y resolver_plantilla escapa los valores de las variables (migración 022).
#
# SIN onError: un mensaje que no llega es un fallo real y tiene que verse. Con
# `continueRegularOutput` la ejecución quedaba marcada como exitosa, no se
# guardaba nada (EXECUTIONS_DATA_SAVE_ON_SUCCESS=none) y el informe simplemente
# no aparecía en el chat sin dejar rastro en ningún lado. Ahora falla, wf_error
# lo registra en `fallas` y avisa. retryOnFail cubre el hipo transitorio.
def enviar_texto(filas, pos):
    params = {
        "chatId": "={{ $json.chat_id }}",
        "text": "={{ $json.texto }}",
        "additionalFields": {"appendAttribution": False, "parse_mode": "HTML"}}
    if filas:
        params["replyMarkup"] = "inlineKeyboard"
        params["inlineKeyboard"] = {"rows": [
            {"row": {"buttons": [{
                "text": f"={{{{ $json.b[{i}].text }}}}",
                "additionalFields": {"callback_data": f"={{{{ $json.b[{i}].dato }}}}"}}]}}
            for i in range(filas)]}
    return w.node(f"EnviarTexto{filas}", "n8n-nodes-base.telegram", 1.2, params,
                  pos, {"telegramApi": TG},
                  {"retryOnFail": True, "maxTries": 3, "waitBetweenTries": 2000})

for k in range(MAX_FILAS + 1):
    enviar_texto(k, [1100, 40 + k * 110])
    w.link("CuantasFilas", f"EnviarTexto{k}", k)

# --- Rama documento (si viene binario y alguna respuesta lo pide) --------------
w.if_("HayDoc?",
      "={{ ($json.respuestas || []).some(r => r.documento) && $binary && Object.keys($binary).length > 0 }}",
      [220, 860])
w.link("Inicio", "HayDoc?")

# El nodo Postgres descarta el binario (igual que en wf_ingesta), por eso va
# ANTES de armar el item con el documento: PrepDoc lo recupera del trigger.
w.pg("CanalDoc",
     "SELECT canal_de_chat(({{ $json.chat_id }})::bigint) AS canal;",
     [400, 860])
w.link("HayDoc?", "CanalDoc", 0)

w.code("PrepDoc", """
const inp = $('Inicio').first().json;
const canal = $input.first().json.canal || 'telegram';
const r = (inp.respuestas || []).find(x => x.documento);
const binKey = Object.keys($('Inicio').first().binary || {})[0];
return [{ json: { chat_id: inp.chat_id, canal, fileName: r?.documento || 'informe.pdf' },
          binary: { data: $('Inicio').first().binary[binKey] } }];
""", [560, 860])
w.link("CanalDoc", "PrepDoc")

w.if_("DocWa?", "={{ $json.canal === 'whatsapp' }}", [720, 860])
w.link("PrepDoc", "DocWa?")

w.node("EnviarDoc", "n8n-nodes-base.telegram", 1.2, {
    "operation": "sendDocument",
    "chatId": "={{ $json.chat_id }}",
    "binaryData": True,
    "binaryPropertyName": "data",
    "additionalFields": {"appendAttribution": False, "parse_mode": "HTML"}}, [900, 920], {"telegramApi": TG},
    {"onError": "continueRegularOutput"})
w.link("DocWa?", "EnviarDoc", 1)

# WhatsApp manda documentos en dos pasos: subir el binario a /media y después
# referenciarlo por id en un mensaje type=document.
w.node("WaSubirDoc", "n8n-nodes-base.httpRequest", 4.2, {
    "method": "POST", "url": f"{GRAPH}/{WA_PNID}/media",
    "authentication": "genericCredentialType", "genericAuthType": "httpHeaderAuth",
    "sendBody": True, "contentType": "multipart-form-data",
    "bodyParameters": {"parameters": [
        {"name": "messaging_product", "value": "whatsapp"},
        {"name": "file", "parameterType": "formBinaryData",
         "inputDataFieldName": "data"}]},
    "options": {"timeout": 60000}}, [900, 800], {"httpHeaderAuth": WA},
    {"onError": "continueRegularOutput"})
w.link("DocWa?", "WaSubirDoc", 0)

w.node("WaMandarDoc", "n8n-nodes-base.httpRequest", 4.2, {
    "method": "POST", "url": f"{GRAPH}/{WA_PNID}/messages",
    "authentication": "genericCredentialType", "genericAuthType": "httpHeaderAuth",
    "sendBody": True, "specifyBody": "json",
    "jsonBody": "={{ JSON.stringify({ messaging_product: 'whatsapp', "
                "to: String($('PrepDoc').first().json.chat_id), type: 'document', "
                "document: { id: $json.id, "
                "filename: $('PrepDoc').first().json.fileName } }) }}",
    "options": {"timeout": 30000}}, [1100, 800], {"httpHeaderAuth": WA},
    {"onError": "continueRegularOutput"})
w.link("WaSubirDoc", "WaMandarDoc")

w.dump("workflows/wf_enviar.json")
