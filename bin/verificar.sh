#!/usr/bin/env bash
# Invariantes estructurales del repositorio. Sin LLM.
#
# POR QUÉ EXISTE
#
# Las reglas importantes de Chasqui no pueden depender de que un agente las
# recuerde. Si una regla puede comprobarse sin un modelo, se comprueba sin un
# modelo. Este script es el juez: código de salida = número de violaciones.
#
# USO
#   bash bin/verificar.sh            todo, incluidas las pruebas SQL
#   bash bin/verificar.sh --rapido   omite bin/pruebas.sh (para hooks)
#
# Los chequeos que necesitan Postgres se reportan OMITIDO si está abajo; nunca
# se levantan servicios desde acá.
set -uo pipefail

cd "$(dirname "$0")/.."
shopt -s nullglob

RAPIDO=0
[ "${1:-}" = "--rapido" ] && RAPIDO=1

VIOLACIONES=0
ok()      { printf '  \033[32mOK\033[0m      %s\n' "$1"; }
falla()   { printf '  \033[31mFALLA\033[0m   %s\n' "$1"; VIOLACIONES=$((VIOLACIONES+1)); }
omitido() { printf '  \033[33mOMITIDO\033[0m %s\n' "$1"; }
titulo()  { printf '\n%s\n' "$1"; }

postgres_arriba() {
  docker compose ps --status running --services 2>/dev/null | grep -qx postgres
}

# ── 1. Los workflows son reproducibles por sus generadores ───────────────────
# Un JSON editado a mano en n8n y exportado se pierde en la próxima generación.
# Se regenera en un directorio aparte para no tocar el árbol de trabajo.
titulo "1. workflows/*.json reproducibles"
TMPWF=$(mktemp -d); trap 'rm -rf "$TMPWF"' EXIT
mkdir -p "$TMPWF/workflows"
set -a; [ -f .env ] && . ./.env; set +a
for gen in bin/gen_wf_*.py; do
  # gen_wf_ejecutar.py escribe con open() en vez de w.dump(): se acepta
  # cualquiera de las dos formas en vez de uniformar el generador (eso sería
  # refactor de producto, fuera del alcance de esta arquitectura).
  destino=$(grep -oE '"workflows/[a-z_]+\.json"' "$gen" | head -1 \
            | sed -E 's/"workflows\/(.*)\.json"/\1.json/')
  [ -z "$destino" ] && { falla "$gen: no se pudo determinar su salida"; continue; }
  if ! ( cd "$TMPWF" && python3 "$OLDPWD/$gen" >/dev/null 2>&1 ); then
    falla "$gen: el generador no corre"
    continue
  fi
  if diff -q "workflows/$destino" "$TMPWF/workflows/$destino" >/dev/null 2>&1; then
    ok "workflows/$destino"
  else
    falla "workflows/$destino difiere de $gen (¿editado a mano?)"
  fi
done

# ── 2. db/actual/ al día y no editado a mano ─────────────────────────────────
titulo "2. db/actual/ refleja el catálogo vivo"
if ! postgres_arriba; then
  omitido "postgres abajo — no se puede contrastar db/actual/"
elif [ ! -d db/actual ]; then
  falla "db/actual/ no existe: correr bin/gen_estado_sql.sh"
else
  TMPACT=$(mktemp -d)
  cp -r db/actual "$TMPACT/previo"
  if bash bin/gen_estado_sql.sh >/dev/null 2>&1 && diff -rq "$TMPACT/previo" db/actual >/dev/null; then
    # Los números salen del MANIFIESTO recién regenerado, no de este archivo:
    # cuando la 074 borró una función, el texto fijo seguía diciendo 160.
    ok "db/actual/ al día ($(grep -E '^(funciones|vistas|tablas):' db/actual/MANIFIESTO.txt \
                             | tr -s ' \n' ' ' | sed 's/ $//'))"
  else
    falla "db/actual/ difiere del catálogo: regenerado, revisar 'git diff db/actual'"
  fi
  rm -rf "$TMPACT"
fi

# ── 3. Ninguna migración ya commiteada fue modificada ────────────────────────
# schema_migraciones sólo guarda (archivo, aplicada_en) — no hay hash, así que
# la inmutabilidad no se puede contrastar contra la base sin cambiar el esquema
# de producto. El sustituto honesto es git: una migración commiteada que aparece
# modificada en el árbol de trabajo es, casi con certeza, una ya aplicada.
titulo "3. migraciones commiteadas inmutables"
if [ ! -d db/base ]; then falla "falta db/base/: el baseline es la instalación"; fi
# --diff-filter=M: sólo contenido modificado. Un archivo movido o borrado no es
# una violación — las 73 originales se archivaron a propósito en
# docs/historico/migraciones/ al crear el baseline.
MODIF=$(git diff --name-only --diff-filter=M HEAD -- db/migraciones/ docs/historico/migraciones/ db/base/ 2>/dev/null)
if [ -z "$MODIF" ]; then
  ok "ninguna migración ni archivo de base modificado"
else
  while read -r m; do falla "modificada: $m (escribir una migración nueva)"; done <<< "$MODIF"
fi

# ── 4. Numeración de migraciones secuencial y sin huecos ─────────────────────
# Arranca en 074: de la 001 a la 073 las absorbió db/base/ (Chasqui v0) y están
# archivadas en docs/historico/migraciones/.
titulo "4. numeración de migraciones (desde 074)"
ESPERADO=74
HUECOS=0
for f in db/migraciones/[0-9][0-9][0-9]_*.sql; do
  n=$(basename "$f" | cut -c1-3)
  n=$((10#$n))
  while [ "$n" -gt "$ESPERADO" ]; do
    falla "falta la migración $(printf '%03d' "$ESPERADO")"
    HUECOS=$((HUECOS+1)); ESPERADO=$((ESPERADO+1))
  done
  [ "$n" -lt "$ESPERADO" ] && { falla "número repetido: $(basename "$f")"; HUECOS=$((HUECOS+1)); }
  ESPERADO=$((n+1))
done
if [ "$HUECOS" -eq 0 ]; then
  if [ "$ESPERADO" -eq 74 ]; then
    ok "ninguna migración pendiente sobre el baseline (db/base/ = v0)"
  else
    ok "$((ESPERADO-74)) migración(es) sobre el baseline, secuencia completa"
  fi
fi

# ── 5. Toda migración explica su porqué ──────────────────────────────────────
# La convención del proyecto: cabecera en prosa con el problema medido. No se
# mide la calidad, sólo que exista algo que leer antes del primer SQL.
# Sin excepciones desde el baseline: las diez migraciones antiguas sin cabecera
# quedaron absorbidas por db/base/ y archivadas. La regla aplica a todo lo nuevo.
titulo "5. toda migración trae cabecera con el porqué"
SINCAB=0
for f in db/migraciones/[0-9][0-9][0-9]_*.sql; do
  lineas=$(awk 'BEGIN{n=0} /^--/{n++; next} /^[[:space:]]*$/{next} {exit} END{print n}' "$f")
  if [ "${lineas:-0}" -lt 5 ]; then
    falla "$(basename "$f"): cabecera de ${lineas:-0} líneas (mínimo 5)"
    SINCAB=$((SINCAB+1))
  fi
done
[ "$SINCAB" -eq 0 ] && ok "todas las migraciones traen cabecera"

# ── 6. Integridad de las decisiones ──────────────────────────────────────────
# Referencias resueltas, cadenas de supersede coherentes, rutas existentes e
# índice al día. No se juzga el contenido: eso es criterio humano.
titulo "6. decisiones coherentes"
if [ ! -d decisiones ]; then
  omitido "no existe decisiones/"
else
  SALIDA=$(python3 bin/verificar_decisiones.py 2>&1) || true
  if [ -z "$SALIDA" ]; then
    ok "$(ls decisiones/*.md 2>/dev/null | grep -vcE 'README|INDICE|deuda') decisiones, referencias resueltas"
  else
    while read -r l; do [ -n "$l" ] && falla "$l"; done <<< "$SALIDA"
  fi
fi

# ── 7. Las pruebas SQL siguen verdes ─────────────────────────────────────────
titulo "7. bancos de prueba"
if [ "$RAPIDO" = "1" ]; then
  omitido "--rapido: no se corrió bin/pruebas.sh"
elif ! postgres_arriba; then
  omitido "postgres abajo — no se corrieron las pruebas"
else
  if bash bin/pruebas.sh >/tmp/verificar_pruebas.log 2>&1; then
    ok "los 7 bancos pasan"
  else
    falla "bin/pruebas.sh falló — ver /tmp/verificar_pruebas.log"
  fi
fi

# ── 8. El baseline no trae entorno ni datos de un cliente ────────────────────
# Dos veces se coló producto ajeno en db/base/001_contenido.sql y las dos las
# encontró una persona leyendo: los formatos `tabular_%` que el sistema APRENDIÓ
# del POS de un negocio, y `portal_url_base` con el túnel efímero de la máquina
# donde se generó v0 —que hace que una instalación nueva mande enlaces de portal,
# con token de sesión adentro, a un dominio de otro—.
#
# El criterio de gen_base.sh (columna de pertenencia) no ve ninguno de los dos.
# Esto es la red: lo que entra al baseline se instala en TODAS las bases nuevas.
titulo "8. el baseline no trae entorno ni datos de cliente"
BASE_SUCIA=0
if [ -f db/base/001_contenido.sql ]; then
  URLS=$(grep -oE 'https?://[^"'"'"' ]+' db/base/001_contenido.sql | sort -u)
  if [ -n "$URLS" ]; then
    while read -r u; do falla "URL de entorno en el baseline: $u"; BASE_SUCIA=1; done <<< "$URLS"
  fi
  APRENDIDOS=$(grep -c "^INSERT INTO public.formatos_documento .*, '\(inferido\|aprendido\)');" \
                 db/base/001_contenido.sql || true)
  if [ "${APRENDIDOS:-0}" -gt 0 ]; then
    falla "$APRENDIDOS formato(s) aprendido(s) de un cliente en el baseline (origen <> semilla)"
    BASE_SUCIA=1
  fi
  PROPIOS=$(grep -c "^INSERT INTO public.parametros (negocio_id.*VALUES ([0-9]" \
              db/base/001_contenido.sql || true)
  if [ "${PROPIOS:-0}" -gt 0 ]; then
    falla "$PROPIOS parámetro(s) de un negocio concreto en el baseline (negocio_id no nulo)"
    BASE_SUCIA=1
  fi
  [ "$BASE_SUCIA" -eq 0 ] && ok "sin URLs, formatos aprendidos ni filas de un negocio"
else
  omitido "no existe db/base/001_contenido.sql"
fi

# ── 9. Ninguna sobrecarga deja una llamada ambigua ───────────────────────────
# La 073 le agregó un tercer parámetro con DEFAULT a ingesta_identificar_tabular
# y CREATE OR REPLACE creó una SEGUNDA función en vez de reemplazar: con las dos
# vivas, toda llamada de dos argumentos era ambigua y Postgres la rechazaba
# antes de ejecutarla. Rompió los tres scripts de carga de datos de prueba desde
# ese día y nadie lo vio, porque wf_ingesta pasa los tres.
#
# Las sobrecargas legítimas no se tocan: hallazgos_generar y hallazgos_compras
# tienen una firma de dos argumentos SIN default, que es la que despacha
# ejecucion_preparar. Lo que se prohíbe es el par que Postgres no puede resolver.
titulo "9. sobrecargas sin ambigüedad"
if ! postgres_arriba; then
  omitido "postgres abajo — no se pudo leer el catálogo"
else
  AMBIGUAS=$(docker compose exec -T -e PGPASSWORD="$CHASQUI_DB_PASSWORD" postgres \
    psql -qtAX -U "$CHASQUI_DB_USER" -d "$CHASQUI_DB" -c "
      SELECT format('%s(%s) es ambigua con %s(%s)',
                    p1.proname, pg_get_function_identity_arguments(p1.oid),
                    p2.proname, pg_get_function_identity_arguments(p2.oid))
        FROM pg_proc p1
        JOIN pg_namespace n ON n.oid = p1.pronamespace AND n.nspname = 'public'
        JOIN pg_proc p2 ON p2.proname = p1.proname AND p2.oid <> p1.oid
                       AND p2.pronamespace = p1.pronamespace
       WHERE p1.pronargs BETWEEN p2.pronargs - p2.pronargdefaults AND p2.pronargs
         AND p1.pronargs < p2.pronargs
         AND (SELECT coalesce(array_agg(t ORDER BY o), '{}')
                FROM unnest(p1.proargtypes::oid[]) WITH ORDINALITY x(t,o))
           = (SELECT coalesce(array_agg(t ORDER BY o), '{}')
                FROM unnest(p2.proargtypes::oid[]) WITH ORDINALITY y(t,o)
               WHERE o <= p1.pronargs);" 2>/dev/null)
  if [ -z "$AMBIGUAS" ]; then
    ok "ninguna llamada queda sin candidata única"
  else
    while read -r a; do [ -n "$a" ] && falla "$a"; done <<< "$AMBIGUAS"
  fi
fi

printf '\n'
if [ "$VIOLACIONES" -eq 0 ]; then
  printf '\033[32mSin violaciones.\033[0m\n'
else
  printf '\033[31m%s violación(es).\033[0m\n' "$VIOLACIONES"
fi
exit "$VIOLACIONES"
