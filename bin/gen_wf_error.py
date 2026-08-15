#!/usr/bin/env python3
"""wf_error — error workflow de los otros seis. Registra la falla en 'fallas',
clasifica si es transitoria y avisa a los admins con el detalle técnico. El
usuario final nunca ve un stack trace (su aviso lo dan wf_ejecutar/wf_cron)."""
from wf_lib import WF, PG

w = WF("wfError0000000000001", "wf_error")

w.node("Error", "n8n-nodes-base.errorTrigger", 1, {}, [0, 300])

# Clasifica transitoria (timeout, 429, ECONNRESET...) y arma el registro.
w.code("Clasificar", """
const e = $input.first().json;
const msg = (e.execution?.error?.message || e.error?.message || '').toString();
const transitoria = /timeout|ETIMEDOUT|ECONNRESET|429|rate.?limit|EAI_AGAIN|socket hang up/i.test(msg);
return [{ json: {
  workflow: e.workflow?.name || null,
  tipo: transitoria ? 'transitoria' : 'permanente',
  transitoria,
  detalle: {
    mensaje: msg.slice(0, 500),
    nodo: e.execution?.lastNodeExecuted || null,
    execution_id: e.execution?.id || null
  }
} }];
""", [220, 300])
w.link("Error", "Clasificar")

# Registra en fallas.
w.pg("Registrar",
     "INSERT INTO fallas (workflow, tipo, transitoria, detalle) VALUES ("
     "'{{ String($json.workflow).replaceAll(\"'\",\"''\") }}', "
     "'{{ $json.tipo }}', {{ $json.transitoria }}, "
     "'{{ JSON.stringify($json.detalle).replaceAll(\"'\",\"''\") }}'::jsonb) "
     "RETURNING id;",
     [440, 300])
w.link("Clasificar", "Registrar")

# Arma notificación a los admins con el detalle técnico.
w.pg("Admins",
     "SELECT jsonb_build_object("
     "  'chat_id', telegram_chat_id,"
     "  'respuestas', jsonb_build_array(jsonb_build_object("
     "    'plantilla', '⚠️ Falla en {{ $('Clasificar').first().json.workflow }} "
     "(' || '{{ $('Clasificar').first().json.tipo }}' || '): "
     "{{ String($('Clasificar').first().json.detalle.mensaje).replaceAll(\"'\",\"''\").slice(0,200) }}',"
     "    'vars', '{}'))) AS payload"
     " FROM usuarios WHERE rol='admin' AND telegram_chat_id IS NOT NULL;",
     [660, 300])
w.link("Registrar", "Admins")

w.code("FanoutAdmin", """
return $input.all().map(i => ({ json: i.json.payload }));
""", [880, 300])
w.link("Admins", "FanoutAdmin")

w.node("AvisarAdmin", "n8n-nodes-base.executeWorkflow", 1.2, {
    "workflowId": {"__rl": True, "value": "wfEnviar00000000001", "mode": "id"},
    "workflowInputs": {"mappingMode":"defineBelow","value":{}},
    "options": {}}, [1100, 300], None, {"onError":"continueRegularOutput"})
w.link("FanoutAdmin", "AvisarAdmin")

w.dump("workflows/wf_error.json")
