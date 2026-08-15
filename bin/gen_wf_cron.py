#!/usr/bin/env python3
"""wf_cron — cada 5 min: reaper de ejecuciones colgadas y expiración de sesiones.
mantenimiento_ciclo() hace el trabajo en Postgres y devuelve notificaciones que
se despachan una por una a wf_enviar."""
from wf_lib import WF, PG

w = WF("wfCron00000000000001", "wf_cron")

w.node("Cada5min", "n8n-nodes-base.scheduleTrigger", 1.2,
    {"rule": {"interval": [{"field": "minutes", "minutesInterval": 5}]}}, [0, 300])

w.pg("Mantenimiento", "SELECT mantenimiento_ciclo() AS r;", [220, 300])
w.link("Cada5min", "Mantenimiento")

# Una salida por notificación {chat_id, respuestas}
w.code("Fanout", """
const notifs = $input.first().json.r?.notificaciones || [];
return notifs.map(n => ({ json: n }));
""", [440, 300])
w.link("Mantenimiento", "Fanout")

# Llama a wf_enviar por cada notificación
w.node("Avisar", "n8n-nodes-base.executeWorkflow", 1.2, {
    "workflowId": {"__rl": True, "value": "wfEnviar00000000001", "mode": "id"},
    "workflowInputs": {"mappingMode": "defineBelow", "value": {}},
    "mode": "each", "options": {}}, [660, 300],
    None, {"onError": "continueRegularOutput"})
w.link("Fanout", "Avisar")

w.dump("workflows/wf_cron.json")
