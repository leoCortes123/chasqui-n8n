#!/usr/bin/env python3
"""Genera agent-context/generated/*.json desde fuentes ya generadas del repo.

Fuente de datos (ninguna opinion, ninguna consulta a la base):
  - db/actual/INDICE.md   funciones (nombre, firma, archivo), vistas y tablas
  - db/actual/grafo.json  llamadas entre funciones, entrada desde n8n y uso de tablas
  - workflows/wf_*.json   inventario de nodos, triggers y errorWorkflow
  - db/actual/MANIFIESTO.txt conteos del catalogo vivo

Uso: python3 bin/gen_agent_context.py
Regenerar es seguro: solo escribe agent-context/generated/. No toca la base.
"""

import json
import re
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
DESTINO = RAIZ / "agent-context" / "generated"


def cargar_grafo():
    return json.loads((RAIZ / "db/actual/grafo.json").read_text())["funciones"]


def parsear_indice():
    texto = (RAIZ / "db/actual/INDICE.md").read_text()
    seccion = texto.split("## Funciones")[1].split("## Vistas")[0]
    funciones = []
    for linea in seccion.splitlines():
        m = re.match(r"\| `(\w+)` \| (.+?) \| (.+?) \| `(.+?)` \|", linea.strip())
        if m:
            funciones.append(
                {
                    "symbol": m.group(1),
                    "args": m.group(2).strip(),
                    "returns": m.group(3).strip(),
                    "file": f"db/actual/funciones/{m.group(4)}",
                }
            )
    vistas = re.findall(r"\| `(\w+)` \| \d+ \|", texto.split("## Vistas")[1].split("## Tablas")[0])
    tablas = re.findall(r"\| `(\w+)` \| \d+ \|", texto.split("## Tablas")[1])
    return funciones, vistas, tablas


def gen_symbols(grafo, funciones):
    por_archivo = {}
    for nombre, datos in grafo.items():
        archivos = sorted(
            {f["file"].split("/")[-1] for f in funciones if f["symbol"] == nombre}
        )
        por_archivo[nombre] = (
            [f"db/actual/funciones/{a}" for a in archivos]
            if archivos
            else []
        )
    simbolos = []
    for f in funciones:
        g = grafo.get(f["symbol"], {})
        simbolos.append(
            {
                "symbol": f["symbol"],
                "type": "function",
                "args": f["args"],
                "returns": f["returns"],
                "file": f["file"],
                "overloads": por_archivo[f["symbol"]],
                "calls": sorted(g.get("llama_a", [])),
                "called_by_sql": sorted(g.get("llamada_por", [])),
                "entry_points": sorted(g.get("llamada_desde", [])),
                "tables_used": sorted(g.get("usa", [])),
            }
        )
    return {
        "_": "Generado por bin/gen_agent_context.py. No editar a mano. "
        "llamada_por/llama_a salen de db/actual/grafo.json; entry_points lista "
        "workflows n8n o scripts que la invocan externamente.",
        "count": len(simbolos),
        "functions": simbolos,
    }


def gen_dependencies(grafo, vistas, tablas):
    objetos = {}
    for nombre in sorted(set(vistas) | set(tablas)):
        referenciada_por = sorted(f for f, d in grafo.items() if nombre in d.get("usa", []))
        if referenciada_por:
            objetos[nombre] = {"kind": "view" if nombre in vistas else "table", "referenced_by_functions": referenciada_por}
    aristas_n8n = {}
    for nombre, datos in grafo.items():
        for origen in datos.get("llamada_desde", []):
            if origen.startswith("n8n:"):
                wf = origen.split(":", 1)[1].removesuffix(".json")
                aristas_n8n.setdefault(wf, set()).add(nombre)
    return {
        "_": "Generado por bin/gen_agent_context.py. Referencias estaticas: quien "
        "menciona cada tabla/vista segun grafo.json, y que funciones llama cada "
        "workflow n8n directamente. No distingue lectura de escritura.",
        "objects": objetos,
        "workflows_to_functions": {k: sorted(v) for k, v in sorted(aristas_n8n.items())},
    }


def gen_workflows():
    flujos = []
    for ruta in sorted((RAIZ / "workflows").glob("wf_*.json")):
        w = json.loads(ruta.read_text())
        nodos = [
            {"name": n.get("name"), "type": n.get("type")}
            for n in w.get("nodes", [])
        ]
        sub = []
        sql = []
        for n in w.get("nodes", []):
            p = json.dumps(n.get("parameters", {}), ensure_ascii=False)
            if n.get("type", "").endswith("executeWorkflow"):
                wid = n.get("parameters", {}).get("workflowId")
                valor = wid.get("value") if isinstance(wid, dict) else wid
                sub.append(valor if isinstance(valor, str) else json.dumps(wid))
            for fn in re.findall(r"\b([a-z_]+)\s*\(", p):
                pass
            sql += sorted(set(re.findall(r"(?:SELECT\s+\*?\s*FROM\s+|SELECT\s+)([a-z_]+)\(", p)))
        flujos.append(
            {
                "name": w.get("name"),
                "file": str(ruta.relative_to(RAIZ)),
                "generator": f"bin/gen_{ruta.stem}.py",
                "active_in_repo": w.get("active"),
                "error_workflow": w.get("settings", {}).get("errorWorkflow"),
                "node_count": len(nodos),
                "nodes": nodos,
                "calls_subworkflows": sorted(set(sub)),
                "sql_functions_called": sorted(set(sql)),
            }
        )
    return {
        "_": "Generado por bin/gen_agent_context.py. Los JSON son generados por "
        "los gen_wf_*.py (fuente real); active=false en el repo, el estado vivo "
        "vive en la base n8n. sql_functions_called sale de regex sobre los "
        "parametros de los nodos: informativo, no exhaustivo.",
        "workflows": flujos,
    }


def gen_database(funciones, vistas, tablas):
    manifiesto = (RAIZ / "db/actual/MANIFIESTO.txt").read_text()
    contenido = re.search(r"contenido:\s*(\d+) filas en (\d+) tablas", manifiesto)
    return {
        "_": "Generado por bin/gen_agent_context.py desde db/actual/. Los enums "
        "NO estan aqui: gen_estado_sql.sh no los vuelca (deuda D-010); su "
        "definicion congelada esta en db/base/000_esquema.sql.",
        "functions": len(funciones),
        "views": sorted(vistas),
        "tables": sorted(tablas),
        "contenido_rows": int(contenido.group(1)) if contenido else None,
        "contenido_tables": int(contenido.group(2)) if contenido else None,
    }


def main():
    DESTINO.mkdir(parents=True, exist_ok=True)
    grafo = cargar_grafo()
    funciones, vistas, tablas = parsear_indice()
    artefactos = {
        "symbols.json": gen_symbols(grafo, funciones),
        "dependencies.json": gen_dependencies(grafo, vistas, tablas),
        "database.json": gen_database(funciones, vistas, tablas),
        "workflows.json": gen_workflows(),
    }
    for nombre, datos in artefactos.items():
        (DESTINO / nombre).write_text(json.dumps(datos, ensure_ascii=False, indent=1) + "\n")
        print(f"{nombre}: ok")


if __name__ == "__main__":
    main()
