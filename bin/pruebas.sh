#!/usr/bin/env bash
# Corre los bancos de prueba de db/pruebas/ y resume el resultado.
#
# Hasta ahora el comando de cada banco estaba en la cabecera de su propio
# archivo y se copiaba a mano; esto es lo mismo, escrito una sola vez.
#
#   bash bin/pruebas.sh                      # todos
#   bash bin/pruebas.sh aceptacion router    # solo esos
#   bash bin/pruebas.sh -v                   # con la salida completa de cada banco
#
# Todos los bancos corren dentro de una transacción que termina en ROLLBACK: no
# dejan rastro y se pueden correr contra producción.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

VERBOSE=0
BANCOS=()
for arg in "$@"; do
  case "$arg" in
    -v|--verbose) VERBOSE=1 ;;
    *) BANCOS+=("$arg") ;;
  esac
done
if [ ${#BANCOS[@]} -eq 0 ]; then
  BANCOS=(aceptacion empty_state carga_sin_perdida ingesta_sin_modelo
          reglas_comparativas router_casos escenarios_generados)
fi

SALIDA=$(mktemp -d)
trap 'rm -rf "$SALIDA"' EXIT
FALLAS=0

for banco in "${BANCOS[@]}"; do
  archivo="db/pruebas/${banco}.sql"
  if [ ! -f "$archivo" ]; then
    echo "  [ERROR] no existe $archivo"; FALLAS=$((FALLAS+1)); continue
  fi
  printf '%-24s ' "$banco"
  if ! docker compose exec -T -e PGPASSWORD="$CHASQUI_DB_PASSWORD" postgres \
        psql -U "$CHASQUI_DB_USER" -d "$CHASQUI_DB" \
        < "$archivo" > "$SALIDA/$banco.txt" 2>&1; then
    echo "ERROR"
    tail -20 "$SALIDA/$banco.txt" | sed 's/^/    /'
    FALLAS=$((FALLAS+1))
    continue
  fi

  # Cada banco dice su resultado a su manera: unos terminan con una fila de
  # conteos, `reglas_comparativas` con una columna t/f, y `router_casos` con
  # salidas normalizadas que hay que mirar.
  #
  # `router_casos` NO lleva golden a propósito: tres de sus casos —/salud,
  # /matching, /pendientes— son comandos de administración que reportan la base
  # ENTERA, así que su salida cambia con cada dataset cargado y ninguna foto
  # guardada podría seguir siendo válida. Se corre para ver que no reviente y
  # se lee con `-v`.
  resumen=$(grep -E '^\s+[0-9]+ \|' "$SALIDA/$banco.txt" | tail -1 | tr -s ' ')
  if [ -n "$resumen" ]; then
    cabecera=$(grep -E 'pasaron' "$SALIDA/$banco.txt" | tail -1 | tr -s ' ')
    echo "$cabecera => $resumen"
    fallaron=$(echo "$resumen" | awk -F'|' '{print $2}' | tr -d ' ')
    [ "${fallaron:-0}" != "0" ] && FALLAS=$((FALLAS+1))
  elif grep -q 'regla_esperada' "$SALIDA/$banco.txt"; then
    # reglas_comparativas imprime una fila por regla con t/f: falla si hay una f.
    nf=$(awk '/regla_esperada/{v=1} v && /\| f$/{n++} END{print n+0}' \
         "$SALIDA/$banco.txt")
    nt=$(awk '/regla_esperada/{v=1} v && /\| t$/{n++} END{print n+0}' \
         "$SALIDA/$banco.txt")
    echo "$nt reglas dispararon, $nf no"
    [ "$nf" != "0" ] && FALLAS=$((FALLAS+1))
  else
    # Bancos sin veredicto propio (router_casos imprime salida normalizada):
    # se comparan contra su golden file si existe, y si no, se informa.
    golden="db/pruebas/${banco}.esperado.txt"
    if [ -f "$golden" ]; then
      if diff -q "$golden" "$SALIDA/$banco.txt" >/dev/null; then
        echo "salida normalizada idéntica al golden"
      else
        echo "SALIDA DISTINTA del golden ($golden)"
        diff "$golden" "$SALIDA/$banco.txt" | head -30 | sed 's/^/    /'
        FALLAS=$((FALLAS+1))
      fi
    else
      echo "$(grep -cE '=>' "$SALIDA/$banco.txt") casos; sin veredicto propio"
    fi
  fi

  if [ "$VERBOSE" = 1 ]; then
    sed 's/^/    /' "$SALIDA/$banco.txt"
  else
    grep -E '\| FALLA|^ FAIL ' "$SALIDA/$banco.txt" | sed 's/^/    /'
  fi
done

echo
if [ "$FALLAS" -eq 0 ]; then
  echo "todos los bancos pasaron"
else
  echo "$FALLAS banco(s) con fallas"
fi
exit "$FALLAS"
