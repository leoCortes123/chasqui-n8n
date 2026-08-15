"""Utilidades compartidas para generar los workflows de Chasqui.
Un formato de nodo probado (n8n 2.31) para no repetirlo en cada generador."""
import json
import os

# Endpoint del LLM. Sale de DEEPSEEK_BASE_URL para poder apuntar a un proxy
# compatible con OpenAI sin editar dos generadores; el default es el de
# siempre. La clave NO viaja acá: vive en la credencial DS de n8n.
LLM_URL = os.environ.get("DEEPSEEK_BASE_URL", "https://api.deepseek.com").rstrip("/") \
          + "/chat/completions"

PG = {"id": "chasquiPg0000000001", "name": "Chasqui Postgres"}
TG = {"id": "chasquiTg0000000001", "name": "Chasqui Telegram"}
DS = {"id": "chasquiDs0000000001", "name": "DeepSeek Header"}
# Header Auth con "Authorization: Bearer <WA_ACCESS_TOKEN>". Se crea a mano en
# n8n (igual que las otras): así el token no viaja en el JSON del workflow ni
# obliga a meter variables de entorno al contenedor.
WA = {"id": "chasquiWa0000000001", "name": "Chasqui WhatsApp"}
GRAPH = "https://graph.facebook.com/v23.0"
ERROR_WF_ID = "wfError0000000000001"

class WF:
    def __init__(self, wid, name):
        self.wid, self.name = wid, name
        self.nodes, self.conns = [], {}

    def _add(self, name, ntype, ver, params, pos, creds=None, extra=None):
        n = {"parameters": params, "id": name, "name": name,
             "type": ntype, "typeVersion": ver, "position": pos}
        if creds: n["credentials"] = creds
        if extra: n.update(extra)
        self.nodes.append(n); return name

    def pg(self, name, query, pos, cont=False, extra=None):
        extra = extra or ({"onError": "continueRegularOutput"} if cont else None)
        return self._add(name, "n8n-nodes-base.postgres", 2.6,
            {"operation": "executeQuery", "query": query, "options": {}},
            pos, {"postgres": PG}, extra)

    def code(self, name, js, pos):
        return self._add(name, "n8n-nodes-base.code", 2, {"jsCode": js}, pos)

    def if_(self, name, left, pos, op=None):
        op = op or {"type": "boolean", "operation": "true", "singleValue": True}
        return self._add(name, "n8n-nodes-base.if", 2.2, {"conditions": {
            "options": {"typeValidation": "loose"}, "combinator": "and",
            "conditions": [{"leftValue": left, "rightValue": True, "operator": op}]}}, pos)

    def node(self, *a, **k):  # passthrough para nodos especiales
        return self._add(*a, **k)

    def link(self, a, b, idx=0):
        self.conns.setdefault(a, {}).setdefault("main", [])
        while len(self.conns[a]["main"]) <= idx: self.conns[a]["main"].append([])
        self.conns[a]["main"][idx].append({"node": b, "type": "main", "index": 0})

    def dump(self, path, active=False, settings=None):
        # errorWorkflow por defecto: sin esto wf_error no se dispara nunca y una
        # excepción de nodo muere en el log de n8n —ni en `fallas`, ni avisada.
        # wf_error se excluye solo (no puede ser su propio error workflow).
        base = {"executionOrder": "v1"}
        if self.wid != ERROR_WF_ID:
            base["errorWorkflow"] = ERROR_WF_ID
        wf = {"id": self.wid, "name": self.name, "nodes": self.nodes,
              "connections": self.conns,
              "settings": settings or base, "active": active}
        open(path, "w").write(json.dumps(wf, indent=2, ensure_ascii=False))
        print(f"{self.name}: {len(self.nodes)} nodos -> {path}")
