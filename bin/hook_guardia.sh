#!/usr/bin/env bash
# Guardia de PreToolUse: bloquea la edición de archivos generados.
# Lee el JSON del hook por stdin y sale 2 para bloquear.
#
# Existe porque la regla "no editar los generados" es la más fácil de violar sin
# darse cuenta: el archivo está ahí, se ve normal, y el cambio se pierde en la
# siguiente regeneración sin ruido.
set -uo pipefail
ENTRADA=$(cat)
RUTA=$(printf '%s' "$ENTRADA" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print((d.get('tool_input') or {}).get('file_path',''))
except Exception:
    print('')
" 2>/dev/null)
[ -z "$RUTA" ] && exit 0

case "$RUTA" in
  */workflows/wf_*.json)
    echo "BLOQUEADO: workflows/wf_*.json lo escriben los generadores." >&2
    echo "Editar bin/gen_wf_<x>.py y correr: python3 bin/gen_wf_<x>.py" >&2
    exit 2 ;;
  */db/actual/*)
    echo "BLOQUEADO: db/actual/ es un volcado del catálogo de Postgres." >&2
    echo "Para cambiar el esquema se escribe una migración nueva y se corre bin/migrar.sh." >&2
    exit 2 ;;
  */decisiones/INDICE.md)
    echo "BLOQUEADO: decisiones/INDICE.md se genera." >&2
    echo "Correr: python3 bin/gen_indice_decisiones.py" >&2
    exit 2 ;;
  */db/migraciones/*)
    NOMBRE=$(basename "$RUTA")
    if git -C "$(dirname "$0")/.." ls-files --error-unmatch "db/migraciones/$NOMBRE" >/dev/null 2>&1; then
      echo "BLOQUEADO: $NOMBRE ya está versionada y probablemente aplicada." >&2
      echo "Una migración aplicada no se edita: se escribe una nueva." >&2
      exit 2
    fi ;;
esac
exit 0
