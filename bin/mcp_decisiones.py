#!/usr/bin/env python3
"""Servidor MCP sobre decisiones/ — la fuente normativa de Chasqui.

Responde "¿cómo hemos decidido que debe funcionar?". La pregunta hermana
—"¿cómo está implementado hoy?"— la responde codebase-memory-mcp sobre
db/actual/, y las dos se mantienen separadas a propósito: un grafo de código no
puede decir qué está bien, y una decisión no puede decir qué existe.

DELIBERADAMENTE PEQUEÑO

Sin embeddings, sin base de datos, sin memoria general, sin nube. Lee archivos
markdown de decisiones/ en cada llamada. El repositorio tiene 164 archivos: un
índice sería infraestructura para un problema que no existe, y una copia más que
se desactualiza.

Protocolo MCP por stdio, sin dependencias fuera de la biblioteca estándar, para
que cualquier cliente lo levante: Claude Code, Codex, Cursor o el inspector.

    npx @modelcontextprotocol/inspector python3 bin/mcp_decisiones.py
"""
import json
import re
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
DECISIONES = RAIZ / "decisiones"
PROTOCOLO = "2024-11-05"


# ── Lectura ──────────────────────────────────────────────────────────────────

def _valor(bruto):
    bruto = bruto.strip()
    if bruto in ("null", "~", ""):
        return None
    if bruto.startswith("[") and bruto.endswith("]"):
        interior = bruto[1:-1].strip()
        return [x.strip().strip("'\"") for x in interior.split(",")] if interior else []
    return bruto.strip("'\"")


def _frontmatter(texto):
    if not texto.startswith("---"):
        return {}, texto
    fin = texto.find("\n---", 3)
    if fin == -1:
        return {}, texto
    campos, clave = {}, None
    for linea in texto[3:fin].splitlines():
        if not linea.strip() or linea.lstrip().startswith("#"):
            continue
        if linea.startswith(("  - ", "- ")):
            if clave:
                campos.setdefault(clave, [])
                if not isinstance(campos[clave], list):
                    campos[clave] = []
                item = linea.split("- ", 1)[1]
                campos[clave].append(item.split("   #")[0].strip())
            continue
        if ":" in linea and not linea.startswith((" ", "\t")):
            clave, _, resto = linea.partition(":")
            clave = clave.strip()
            campos[clave] = _valor(resto)
    return campos, texto[fin + 4:]


def cargar():
    """{id: {campos..., cuerpo, archivo}} — sólo decisiones/*.md, no candidatos."""
    todas = {}
    if not DECISIONES.is_dir():
        return todas
    for f in sorted(DECISIONES.glob("*.md")):
        if f.name in ("README.md", "INDICE.md", "deuda.md"):
            continue
        campos, cuerpo = _frontmatter(f.read_text())
        if not campos.get("id"):
            continue
        campos["cuerpo"] = cuerpo.strip()
        campos["archivo"] = str(f.relative_to(RAIZ))
        todas[campos["id"]] = campos
    return todas


def _resumen(d, con_cuerpo=False):
    r = {k: d.get(k) for k in ("id", "dominio", "estado", "fecha", "titulo",
                               "invariantes", "supersede", "superseded_by",
                               "motivo_reemplazo", "relacionada_con", "afecta",
                               "archivo")}
    if con_cuerpo:
        r["cuerpo"] = d["cuerpo"]
        r["implementada_en"] = d.get("implementada_en")
        r["procedencia"] = d.get("procedencia")
    return {k: v for k, v in r.items() if v not in (None, [], "")}


# ── Herramientas ─────────────────────────────────────────────────────────────

def dominio_contexto(dominio=None, **_):
    """El paso 1 del protocolo en una sola llamada."""
    todas = cargar()
    if dominio:
        d = dominio.lower()
        del_dominio = [x for x in todas.values() if (x.get("dominio") or "").lower() == d]
    else:
        del_dominio = list(todas.values())
    vigentes = [x for x in del_dominio if x.get("estado") == "vigente"]
    superadas = [x for x in del_dominio if x.get("estado") in ("superada", "descartada")]

    relacionados = set()
    for x in del_dominio:
        for r in (x.get("relacionada_con") or []):
            relacionados.add(r)
    relacionadas = [todas[r] for r in sorted(relacionados)
                    if r in todas and todas[r] not in del_dominio]

    invariantes = [f"[{x['id']}] {i}" for x in vigentes for i in (x.get("invariantes") or [])]
    dominios = sorted({(x.get("dominio") or "?") for x in todas.values()})

    if not del_dominio:
        return {
            "dominio": dominio,
            "aviso": ("No hay ninguna decisión registrada para este dominio. "
                      "Eso NO significa que se pueda hacer cualquier cosa: puede "
                      "haber material sin promover en decisiones/candidatos/. "
                      "Ante un cambio de arquitectura sin decisión que lo gobierne, "
                      "la decisión se escribe primero."),
            "dominios_con_decisiones": dominios,
        }
    return {
        "dominio": dominio,
        "invariantes_a_preservar": invariantes,
        "vigentes": [_resumen(x) for x in vigentes],
        "superadas": [_resumen(x) for x in superadas],
        "relacionadas_de_otros_dominios": [_resumen(x) for x in relacionadas],
        "como_seguir": ("Contrastar la implementación de db/actual/ contra estos "
                        "invariantes y reportar las contradicciones ANTES de proponer."),
    }


def decisiones_vigentes(dominio=None, **_):
    todas = cargar().values()
    r = [x for x in todas if x.get("estado") == "vigente"]
    if dominio:
        r = [x for x in r if (x.get("dominio") or "").lower() == dominio.lower()]
    return {"total": len(r), "decisiones": [_resumen(x) for x in r]}


def decision_leer(id=None, **_):
    todas = cargar()
    if id not in todas:
        return {"error": f"no existe {id}", "ids": sorted(todas)}
    return _resumen(todas[id], con_cuerpo=True)


def decisiones_buscar(texto=None, incluir_candidatos=False, **_):
    rx = re.compile(re.escape(texto or ""), re.I)
    r = [_resumen(x) for x in cargar().values()
         if rx.search(x["cuerpo"]) or rx.search(x.get("titulo") or "")
         or any(rx.search(i) for i in (x.get("invariantes") or []))]
    salida = {"total": len(r), "decisiones": r}
    if incluir_candidatos:
        cands = []
        for f in sorted((DECISIONES / "candidatos").rglob("*.md")):
            if rx.search(f.read_text()):
                cands.append(str(f.relative_to(RAIZ)))
        salida["candidatos_sin_promover"] = cands
        salida["aviso_candidatos"] = "Material sin revisar. No gobierna nada."
    return salida


def decision_historia(id=None, **_):
    todas = cargar()
    if id not in todas:
        return {"error": f"no existe {id}"}
    cadena, actual, visto = [], id, set()
    while actual and actual in todas and actual not in visto:
        visto.add(actual)
        d = todas[actual]
        cadena.append({"id": d["id"], "estado": d.get("estado"),
                       "titulo": d.get("titulo"),
                       "motivo_reemplazo": d.get("motivo_reemplazo")})
        actual = d.get("superseded_by")
    anteriores = [{"id": todas[s]["id"], "titulo": todas[s].get("titulo")}
                  for s in (todas[id].get("supersede") or []) if s in todas]
    return {"id": id, "reemplaza_a": anteriores, "cadena_hacia_adelante": cadena,
            "nota": ("Las superadas no se obedecen, pero se leen: explican qué "
                     "enfoque ya se descartó.")}


def decision_por_archivo(ruta=None, **_):
    ruta = (ruta or "").strip()
    base = Path(ruta).stem
    r = []
    for x in cargar().values():
        campos = (x.get("afecta") or []) + (x.get("implementada_en") or [])
        if any(ruta in c or (base and base in c) for c in campos):
            r.append(_resumen(x))
    return {"ruta": ruta, "total": len(r), "decisiones": r,
            "nota": "Vacío no significa libre: puede no haber decisión escrita todavía."}


HERRAMIENTAS = {
    "dominio_contexto": (dominio_contexto,
        "EL PRIMER MOVIMIENTO ante cualquier solicitud. Devuelve, para un dominio: "
        "decisiones vigentes, superadas relevantes, relacionadas de otros dominios "
        "y la lista de invariantes a preservar. Llamar ANTES de leer código.",
        {"dominio": {"type": "string", "description": "core, producto, portal, router, ingesta, hallazgos, alertas… Omitir para ver todo."}}),
    "decisiones_vigentes": (decisiones_vigentes,
        "Sólo las decisiones con estado vigente, opcionalmente de un dominio.",
        {"dominio": {"type": "string"}}),
    "decision_leer": (decision_leer,
        "Una decisión completa: problema medido, decisión, alternativas descartadas, consecuencias.",
        {"id": {"type": "string", "description": "por ejemplo CORE-001"}}),
    "decisiones_buscar": (decisiones_buscar,
        "Busca texto en títulos, invariantes y cuerpos. Con incluir_candidatos "
        "también lista material sin promover, que no gobierna nada.",
        {"texto": {"type": "string"}, "incluir_candidatos": {"type": "boolean"}}),
    "decision_historia": (decision_historia,
        "Cadena de supersede de una decisión: a qué reemplaza y qué la reemplazó, con el motivo.",
        {"id": {"type": "string"}}),
    "decision_por_archivo": (decision_por_archivo,
        "Qué decisiones gobiernan un archivo o una función (campos afecta e implementada_en).",
        {"ruta": {"type": "string", "description": "db/actual/funciones/x.sql, o sólo el nombre de la función"}}),
}


# ── Transporte MCP ───────────────────────────────────────────────────────────

def responder(id_, resultado=None, error=None):
    msg = {"jsonrpc": "2.0", "id": id_}
    if error:
        msg["error"] = {"code": -32603, "message": error}
    else:
        msg["result"] = resultado
    sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    for linea in sys.stdin:
        linea = linea.strip()
        if not linea:
            continue
        try:
            pet = json.loads(linea)
        except json.JSONDecodeError:
            continue
        metodo, id_ = pet.get("method"), pet.get("id")

        if metodo == "initialize":
            responder(id_, {"protocolVersion": PROTOCOLO,
                            "capabilities": {"tools": {}},
                            "serverInfo": {"name": "decisiones-chasqui", "version": "1.0.0"}})
        elif metodo == "tools/list":
            responder(id_, {"tools": [
                {"name": n, "description": desc,
                 "inputSchema": {"type": "object", "properties": props}}
                for n, (_, desc, props) in HERRAMIENTAS.items()]})
        elif metodo == "tools/call":
            p = pet.get("params") or {}
            nombre = p.get("name")
            if nombre not in HERRAMIENTAS:
                responder(id_, error=f"herramienta desconocida: {nombre}")
                continue
            try:
                r = HERRAMIENTAS[nombre][0](**(p.get("arguments") or {}))
                responder(id_, {"content": [{"type": "text",
                                             "text": json.dumps(r, ensure_ascii=False, indent=1)}]})
            except Exception as e:
                responder(id_, error=f"{type(e).__name__}: {e}")
        elif id_ is not None:
            responder(id_, {})


if __name__ == "__main__":
    main()
