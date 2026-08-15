#!/usr/bin/env python3
"""wf_cron — cada 5 min: reaper de ejecuciones colgadas, expiración de sesiones,
alertas proactivas (067) e informes periódicos (068).

mantenimiento_ciclo() hace TODO el trabajo en Postgres y devuelve dos listas:
`notificaciones` (mensajes) que van a wf_enviar, y `ejecuciones` (análisis a
correr) que van a wf_ejecutar. Los dos nodos de despacho no deciden nada: solo
reparten lo que Postgres ya decidió."""
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

# --- Informes periódicos (068) ----------------------------------------------
# Una alerta es un mensaje y wf_cron ya sabía mandarlos; un informe es una
# EJECUCIÓN, así que hace falta llamar a wf_ejecutar. Es el único nodo que la
# proactividad agregó al runtime, y no decide nada: mantenimiento_ciclo ya eligió
# a quién le toca, creó la sesión y creó la ejecución.
w.code("FanoutEjec", """
const ejecs = $('Mantenimiento').first().json.r?.ejecuciones || [];
return ejecs.map(e => ({ json: e }));
""", [440, 480])
w.link("Mantenimiento", "FanoutEjec")

w.node("Analizar", "n8n-nodes-base.executeWorkflow", 1.2, {
    "workflowId": {"__rl": True, "value": "wfEjecutar000000001", "mode": "id"},
    "workflowInputs": {"mappingMode": "defineBelow", "value": {}},
    "mode": "each", "options": {}}, [660, 480],
    None, {"onError": "continueRegularOutput"})
w.link("FanoutEjec", "Analizar")

w.dump("workflows/wf_cron.json")
