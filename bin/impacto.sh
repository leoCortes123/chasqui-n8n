#!/usr/bin/env bash
# Qué se ve afectado si se toca una función. Lee db/actual/grafo.json.
#
#   bash bin/impacto.sh router_procesar_mensaje
#   bash bin/impacto.sh movimientos --tabla
#
# El grafo sale de pg_proc.prosrc, no de un analizador de archivos: ver el
# comentario en bin/gen_estado_sql.sh sobre por qué.
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -ge 1 ] || { echo "uso: bash bin/impacto.sh <función|tabla> [--tabla]" >&2; exit 2; }
[ -f db/actual/grafo.json ] || { echo "falta db/actual/grafo.json: correr bin/gen_estado_sql.sh" >&2; exit 1; }
python3 - "$@" <<'PY'
import json, sys
objetivo = sys.argv[1]
es_tabla = "--tabla" in sys.argv[2:]
g = json.load(open("db/actual/grafo.json"))["funciones"]

if es_tabla:
    usan = sorted(f for f, v in g.items() if objetivo in v["usa"])
    print(f"\n{objetivo} — la usan {len(usan)} funciones\n")
    for f in usan:
        print(f"  {f}")
    print()
    sys.exit(0)

if objetivo not in g:
    print(f"'{objetivo}' no está en el grafo. ¿Es una tabla? probá --tabla", file=sys.stderr)
    sys.exit(1)

v = g[objetivo]

def cierre(clave):
    vistos, borde = set(), {objetivo}
    niveles = []
    while borde:
        siguiente = {x for n in borde for x in g.get(n, {}).get(clave, []) if x not in vistos}
        siguiente -= {objetivo}
        if not siguiente:
            break
        vistos |= siguiente
        niveles.append(sorted(siguiente))
        borde = siguiente
    return niveles

print(f"\n{objetivo}")
print(f"  archivo: db/actual/funciones/{objetivo}.sql")
print(f"  usa    : {', '.join(v['usa']) or '—'}")
if v.get("llamada_desde"):
    print(f"  entrada: la invoca {', '.join(v['llamada_desde'])} (nodo Postgres de n8n)")

print("\n  LLAMA A (hacia abajo)")
for i, nivel in enumerate(cierre("llama_a"), 1):
    print(f"    {i}. {', '.join(nivel)}")
if not v["llama_a"]:
    print("    — no llama a ninguna otra función")

print("\n  LA LLAMAN (hacia arriba: esto es lo que se rompe)")
niveles = cierre("llamada_por")
for i, nivel in enumerate(niveles, 1):
    print(f"    {i}. {', '.join(nivel)}")
if not niveles:
    if v.get("llamada_desde"):
        print(f"    — ningún SQL la llama; entra por n8n: {', '.join(v['llamada_desde'])}")
    else:
        print("    — nadie la llama: ni SQL ni workflow. Candidata a código muerto")
else:
    print(f"\n  alcance total hacia arriba: {sum(len(n) for n in niveles)} funciones")
print()
PY
