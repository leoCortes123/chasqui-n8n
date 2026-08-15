#!/usr/bin/env python3
"""wf_wa_router — entrada por WhatsApp (Cloud API de Meta). Mismo cerebro que
wf_router: normaliza el webhook al MISMO evento {from,chat,texto,...} y llama a
router_procesar_mensaje. La única diferencia es `canal: 'whatsapp'`, que
usuario_de_canal (044) lee del evento para colgar la identidad del canal
correcto y que wf_enviar/wf_ingesta usan para hablar con la Graph API.

Meta valida el webhook con un GET (hub.challenge) antes de aceptar la
suscripción, así que hay dos webhooks sobre la misma ruta: GET contesta el
challenge si el verify_token coincide; POST recibe los mensajes.

Seguridad: Meta no manda un secreto por cabecera como Telegram; firma el body
con X-Hub-Signature-256 (HMAC del app secret). Verificar esa firma necesita el
body crudo y el app secret dentro de n8n, así que por ahora la defensa es la
misma que protege al portal: la RUTA es secreta (WA_WEBHOOK_PATH con sufijo
aleatorio) y se descarta todo update cuyo phone_number_id no sea el nuestro.
TODO: verificar la firma cuando el token del bot viva en el contenedor."""
import os
from wf_lib import WF, PG

VERIFY = os.environ.get("WA_VERIFY_TOKEN", "")
if not VERIFY:
    raise SystemExit(
        "falta WA_VERIFY_TOKEN: corré 'set -a; . ./.env; set +a' antes de "
        "generar, o Meta nunca va a poder verificar el webhook")
PATH = os.environ.get("WA_WEBHOOK_PATH", "whatsapp")
PNID = os.environ.get("WA_PHONE_NUMBER_ID", "")

w = WF("wfWaRouter0000000001", "wf_wa_router")

# --- GET: verificación de la suscripción -------------------------------------
w.node("WebhookGet", "n8n-nodes-base.webhook", 2, {
    "httpMethod": "GET", "path": PATH, "responseMode": "responseNode",
    "options": {}}, [0, 100], None,
    {"webhookId": "wfWaRouterWebhookG01"})

w.code("Verificar", f"""
const q = $input.first().json.query || {{}};
return [{{ json: {{
  ok: q['hub.mode'] === 'subscribe' && q['hub.verify_token'] === {VERIFY!r},
  challenge: q['hub.challenge'] || ''
}} }}];
""", [200, 100])
w.link("WebhookGet", "Verificar")

w.if_("TokenOk?", "={{ $json.ok }}", [380, 100])
w.link("Verificar", "TokenOk?")

# Meta espera el challenge tal cual, en texto plano.
w.node("Challenge", "n8n-nodes-base.respondToWebhook", 1.1, {
    "respondWith": "text",
    "responseBody": "={{ $json.challenge }}",
    "options": {}}, [560, 40])
w.link("TokenOk?", "Challenge", 0)

w.node("Rechazar", "n8n-nodes-base.respondToWebhook", 1.1, {
    "respondWith": "text", "responseBody": "no",
    "options": {"responseCode": 403}}, [560, 160])
w.link("TokenOk?", "Rechazar", 1)

# --- POST: mensajes ----------------------------------------------------------
w.node("Webhook", "n8n-nodes-base.webhook", 2, {
    "httpMethod": "POST", "path": PATH, "responseMode": "onReceived",
    "options": {}}, [0, 400], None,
    {"webhookId": "wfWaRouterWebhookP01"})

# Un webhook puede traer varios entry/changes/messages; sale un item por
# mensaje. Los updates de estado (delivered/read) no traen `messages` y acá
# mueren en silencio, que es lo que corresponde.
w.code("Normalizar", f"""
const PNID = {PNID!r};
const body = $input.first().json.body || {{}};
const out = [];
for (const e of (body.entry || [])) for (const ch of (e.changes || [])) {{
  const v = ch.value || {{}};
  if (PNID && v.metadata?.phone_number_id !== PNID) continue;
  for (const m of (v.messages || [])) {{
    if (!m.from) continue;
    const doc = m.document || null;
    const img = m.image || null;
    const texto = m.text?.body
      || m.interactive?.button_reply?.id
      || m.interactive?.list_reply?.id
      || doc?.caption || img?.caption || '';
    const nombre = (v.contacts || []).find(c => c.wa_id === m.from)?.profile?.name;
    out.push({{ json: {{ evento: {{
      canal: 'whatsapp',
      from: {{ id: m.from, username: nombre || null }},
      chat: {{ id: m.from }},
      texto, tiene_documento: !!(doc || img),
      callback_id: null,           // WhatsApp no exige answerCallbackQuery
      file_id: doc?.id || img?.id || null,
      file_name: doc?.filename || null,
      mime: doc?.mime_type || img?.mime_type || null
    }} }} }});
  }}
}}
return out;
""", [220, 400])
w.link("Webhook", "Normalizar")

# A diferencia del router de Telegram no hay desvío por answerCallbackQuery,
# así que el evento viaja en $json y cada item del lote se procesa solo.
w.pg("Router",
     "SELECT router_procesar_mensaje("
     "'{{ JSON.stringify($json.evento).replaceAll(\"'\",\"''\") }}'"
     "::jsonb) AS r;",
     [440, 400])
w.link("Normalizar", "Router")

w.code("Despachar", """
const evs = $('Normalizar').all();
const out = [];
$input.all().forEach((item, i) => {
  const r = item.json.r || {};
  const ev = evs[i]?.json.evento;
  if ((r.respuestas || []).length)
    out.push({ json: { tipo:'enviar', chat_id:r.chat_id, respuestas:r.respuestas } });
  for (const a of (r.acciones || []))
    out.push({ json: { tipo:a.tipo, chat_id:r.chat_id, ...a, evento: ev } });
});
return out;
""", [660, 400])
w.link("Router", "Despachar")

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
  ]}, "options": {}}, [880, 400])
w.link("Despachar", "Switch")

def exec_wf(name, wid, pos):
    return w.node(name, "n8n-nodes-base.executeWorkflow", 1.2, {
        "workflowId": {"__rl": True, "value": wid, "mode": "id"},
        "workflowInputs": {"mappingMode":"defineBelow","value":{}},
        "options": {}}, pos, None, {"onError":"continueRegularOutput"})

exec_wf("LlamarEnviar", "wfEnviar00000000001", [1100, 280])
w.link("Switch", "LlamarEnviar", 0)

exec_wf("LlamarIngesta", "wfIngesta00000000001", [1100, 400])
w.link("Switch", "LlamarIngesta", 1)

exec_wf("LlamarEjecutar", "wfEjecutar000000001", [1100, 540])
w.link("Switch", "LlamarEjecutar", 2)
exec_wf("EnviarInforme", "wfEnviar00000000001", [1320, 540])
w.link("LlamarEjecutar", "EnviarInforme")

w.dump("workflows/wf_wa_router.json")
