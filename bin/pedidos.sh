#!/usr/bin/env bash
# Qué cambios están en curso. Lee pedidos/*.md; no escribe nada.
#
# POR QUÉ EXISTE
#
# El estado de un cambio a medias no puede vivir en la memoria de una sesión.
# Esto lo lee del disco, que es lo único que sobrevive a cerrar la terminal.
#
# USO
#   bash bin/pedidos.sh            los abiertos
#   bash bin/pedidos.sh --todos    incluye pedidos/archivo/
set -uo pipefail
cd "$(dirname "$0")/.."
shopt -s nullglob

TODOS=0
[ "${1:-}" = "--todos" ] && TODOS=1

campo() { sed -n "s/^$2: *//p" "$1" | head -1 | sed 's/ *$//'; }

fila() {
  local f="$1" est tit dom mig cls
  est=$(campo "$f" estado); tit=$(campo "$f" titulo); dom=$(campo "$f" dominio)
  mig=$(campo "$f" migracion); cls=$(campo "$f" clasificacion)
  local pend total
  total=$(grep -c '^- \[.\]' "$f" || true)
  pend=$(grep -c '^- \[ \]' "$f" || true)
  local color=0
  case "$est" in
    propuesto)  color=33 ;;
    aprobado)   color=36 ;;
    aplicado)   color=32 ;;
    descartado) color=90 ;;
  esac
  printf '  \033[%sm%-11s\033[0m %-28s %s\n' "$color" "$est" "$(basename "$f" .md)" "$tit"
  printf '              dominio %s · %s' "${dom:-—}" "${cls:-—}"
  [ "${mig:-null}" != "null" ] && [ -n "${mig:-}" ] && printf ' · migración %s' "$mig"
  [ "${total:-0}" -gt 0 ] && printf ' · tareas %s/%s' "$((total - pend))" "$total"
  printf '\n'
}

ABIERTOS=(pedidos/[0-9]*.md)
if [ ${#ABIERTOS[@]} -eq 0 ]; then
  echo "No hay pedidos abiertos."
else
  echo "--- Pedidos abiertos (${#ABIERTOS[@]}) ---"
  for f in "${ABIERTOS[@]}"; do fila "$f"; done
fi

if [ "$TODOS" -eq 1 ]; then
  CERRADOS=(pedidos/archivo/[0-9]*.md)
  if [ ${#CERRADOS[@]} -gt 0 ]; then
    printf '\n--- Archivo (%s) ---\n' "${#CERRADOS[@]}"
    for f in "${CERRADOS[@]}"; do fila "$f"; done
  fi
fi

TODOS_LOS=(pedidos/[0-9]*.md pedidos/archivo/[0-9]*.md)
SIG=000
if [ ${#TODOS_LOS[@]} -gt 0 ]; then
  SIG=$(printf '%s\n' "${TODOS_LOS[@]}" | sed -E 's|.*/([0-9]{3}).*|\1|' | sort -n | tail -1)
fi
printf '\nEl próximo pedido es el %03d. Lo escribe la skill /pedido, no una persona.\n' \
       $(( 10#${SIG:-000} + 1 ))
