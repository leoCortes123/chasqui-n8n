#!/usr/bin/env bash
# Contexto de arranque de sesión. Lo invoca el hook SessionStart, pero sirve
# suelto: `bash bin/hook_sesion.sh` imprime con qué hay que empezar.
#
# No inventa nada: lee AGENTS.md, decisiones/ y db/actual/. Si mañana se cambia
# de harness, se pierde la comodidad de que salga solo, no el contenido.
set -uo pipefail
cd "$(dirname "$0")/.."

echo "=== CHASQUI — contrato de trabajo ==="
echo
echo "Leer AGENTS.md antes de tocar nada. Resumen operativo:"
echo
echo "  db/actual/  = cómo está HOY (una definición por objeto)"
echo "  db/migraciones/ = historia; NO es el estado actual"
echo "  decisiones/ = qué GOBIERNA"
echo "  docs/historico/ = no gobierna nada"
echo
echo "Protocolo: dominio -> decisiones vigentes -> código -> impacto ->"
echo "reportar contradicciones -> proponer. La consulta va ANTES de leer código."
echo
if [ -f decisiones/INDICE.md ]; then
  echo "--- Invariantes vigentes ---"
  python3 - <<'PY'
import sys, pathlib
sys.path.insert(0, "bin")
try:
    from mcp_decisiones import cargar
except Exception:
    sys.exit(0)
for d in sorted(cargar().values(), key=lambda x: x["id"]):
    if d.get("estado") != "vigente":
        continue
    for i in (d.get("invariantes") or []):
        print(f"  [{d['id']}] {i}")
PY
  echo
fi
# ── Dónde está el proyecto ───────────────────────────────────────────────────
# Existe porque tres sesiones seguidas gastaron su contexto preguntando lo mismo:
# si esto ya es v0, si hay que aplicar las 73 viejas, si la base tiene datos.
echo "--- Dónde está el proyecto ---"
echo "  Esto YA es Chasqui v0. La instalación de esta máquina se hizo desde"
echo "  db/base/ el 2026-08-19. NO se aplican las 73 de docs/historico/migraciones/."
PROX=$(ls db/migraciones/[0-9][0-9][0-9]_*.sql 2>/dev/null | tail -1        | sed -E 's|.*/([0-9]{3})_.*|\1|')
PROX=$(printf '%03d' $(( 10#${PROX:-073} + 1 )))
echo "  La próxima migración es la $PROX, en db/migraciones/."
if [ -f .env ] && docker compose ps --status running --services 2>/dev/null | grep -qx postgres; then
  set -a; . ./.env; set +a
  NEG=$(docker compose exec -T -e PGPASSWORD="$CHASQUI_DB_PASSWORD" postgres \
        psql -qtAX -U "$CHASQUI_DB_USER" -d "$CHASQUI_DB" \
        -c "select count(*) from negocios" 2>/dev/null | tr -d ' ')
  if [ "${NEG:-x}" = "0" ]; then
    echo "  La base está LIMPIA (0 negocios): es para pruebas de usuario reales."
    echo "  No cargar datos de prueba (bin/cargar_datos_prueba.py) sin que lo pidan."
  elif [ -n "${NEG:-}" ]; then
    echo "  La base tiene $NEG negocio(s) cargado(s)."
  fi
fi
echo
if [ -f db/actual/MANIFIESTO.txt ]; then
  echo "--- Estado del código ---"
  sed -n '3,5p' db/actual/MANIFIESTO.txt | sed 's/^/  /'
fi
echo
echo "Consulta: decisiones/INDICE.md · db/actual/INDICE.md · bash bin/impacto.sh <función>"
