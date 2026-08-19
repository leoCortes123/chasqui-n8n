#!/usr/bin/env bash
# Borra los datos de una prueba y deja la base lista para volver a cargar desde
# cero. Sin preguntas y sin respaldo: los datos de prueba son generados, y hacer
# un dump de 37.000 movimientos sintéticos antes de cada iteración es tiempo
# tirado. Si alguna vez hay datos de un cliente real, `bash bin/respaldo.sh`
# primero, a mano.
#
#   bash bin/limpiar_negocio.sh                     datos + formatos aprendidos
#   bash bin/limpiar_negocio.sh --conservar-formatos  no vuelve a llamar al modelo
#   bash bin/limpiar_negocio.sh --todo                también negocio y usuario
#
# Qué NO borra: el negocio, el usuario y su identidad de Telegram (salvo
# --todo), y todo el contenido del sistema —plantillas, prompts, parámetros
# globales, servicios, módulos, formatos semilla, sinónimos—. Eso no es dato de
# prueba: es Chasqui.
#
# Nunca mata procesos. Si la base está ocupada —una carga en vuelo, el cron de
# n8n, un banco de pruebas— el TRUNCATE se rinde a los 15 segundos, dice quién
# la tiene y sale con error. Se espera y se repite. Matar la corrida de otro
# para ganar un minuto rompe cosas que después hay que adivinar.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

CONSERVAR_FORMATOS=0
TODO=0
for arg in "$@"; do
  case "$arg" in
    --conservar-formatos) CONSERVAR_FORMATOS=1 ;;
    --todo)               TODO=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "opción desconocida: $arg" >&2; exit 2 ;;
  esac
done

pg() {
  docker compose exec -T -e PGPASSWORD="$CHASQUI_DB_PASSWORD" postgres \
    psql -v ON_ERROR_STOP=1 -U "$CHASQUI_DB_USER" -d "$CHASQUI_DB" "$@"
}

# Las tablas de datos de negocio. Va explícita y no derivada del catálogo para
# que se pueda leer de un vistazo qué se pierde. El chequeo de más abajo avisa
# si una migración agregó una tabla que debería estar acá.
#
# Lo que NO puede entrar acá: las doce tablas que `bin/gen_estado_sql.sh` vuelca
# en `db/actual/contenido/`. Esas son contenido del sistema —plantillas, prompts,
# servicios, módulos, tipos de negocio, sinónimos, formatos semilla, y también
# `intenciones` y `metricas_resultado`, que parecen datos y no lo son: son el
# catálogo con el que el router entiende preguntas y el que dice cómo se mide el
# resultado de cada regla. Truncarlas deja a Chasqui sin saber responder.
TABLAS="movimientos, facturas, conteos_inventario, documentos,
        productos, alias, terceros,
        recomendaciones,
        conocimiento, conocimiento_pendiente,
        alertas_enviadas, fallas, cotizaciones, pagos,
        snapshots_negocio, portal_tokens,
        ejecuciones, sesiones"

# Con --todo caen también la identidad y el dueño. El bot vuelve a crear negocio
# y usuario solos en el primer mensaje (PLANES-001), pero se pierden el NIT y el
# plan que tuviera configurados.
if [ "$TODO" -eq 1 ]; then
  TABLAS="$TABLAS, identidades, usuarios, negocios"
fi

# `formatos_documento` y `parametros` mezclan filas del sistema con filas
# aprendidas, así que van por DELETE y no por TRUNCATE.
BORRAR_FORMATOS="DELETE FROM formatos_documento WHERE origen <> 'semilla';"
[ "$CONSERVAR_FORMATOS" -eq 1 ] && BORRAR_FORMATOS="-- formatos aprendidos: se conservan"

# Guardia dura, y no un comentario: si alguien agrega a la lista una tabla que
# `db/actual/contenido/` vuelca, el script se niega a correr. Esto ya pasó —
# `intenciones` y `metricas_resultado` truncadas en una limpieza, con el router
# quedándose sin catálogo de preguntas— y no puede volver a pasar por leer mal
# una lista.
CONTENIDO=$(ls db/actual/contenido/*.sql 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.sql$//')
for t in $(echo "$TABLAS" | tr ',' ' '); do
  for c in $CONTENIDO; do
    if [ "$t" = "$c" ]; then
      echo "ABORTA: '$t' es contenido del sistema (db/actual/contenido/$c.sql)," >&2
      echo "        no dato de prueba. Sacala de TABLAS." >&2
      exit 3
    fi
  done
done

echo "Limpiando $CHASQUI_DB…"

# lock_timeout, no pg_terminate_backend: si está ocupada, se avisa y se sale.
if ! pg -q <<SQL
SET lock_timeout = '15s';
BEGIN;
TRUNCATE TABLE $TABLAS RESTART IDENTITY CASCADE;
$BORRAR_FORMATOS
DELETE FROM parametros WHERE negocio_id IS NOT NULL;
COMMIT;
SQL
then
  echo
  echo "No se pudo: la base está ocupada. Quién la tiene:"
  pg -c "SELECT pid, state, left(regexp_replace(query, '\s+', ' ', 'g'), 60) AS query
           FROM pg_stat_activity
          WHERE datname = current_database() AND pid <> pg_backend_pid()
            AND state = 'active';" || true
  echo "Esperá a que termine y volvé a correrlo. No mates nada."
  exit 1
fi

# Una tabla con negocio_id que no esté en la lista es una prueba que deja rastro
# sin que nadie se entere. No falla —puede ser deliberado— pero se dice.
pg -tA <<'SQL'
WITH listadas AS (
    SELECT unnest(string_to_array(
        'movimientos,facturas,conteos_inventario,documentos,productos,alias,'
        'terceros,recomendaciones,metricas_resultado,intenciones,conocimiento,'
        'conocimiento_pendiente,alertas_enviadas,fallas,cotizaciones,pagos,'
        'snapshots_negocio,portal_tokens,ejecuciones,sesiones,usuarios,'
        'negocios,parametros', ',')) AS t
)
SELECT '  aviso: ' || c.table_name || ' tiene negocio_id y no está en la lista '
       || 'de bin/limpiar_negocio.sh'
  FROM information_schema.columns c
  JOIN information_schema.tables tb
    ON tb.table_schema = c.table_schema AND tb.table_name = c.table_name
 WHERE c.table_schema = 'public' AND c.column_name = 'negocio_id'
   AND tb.table_type = 'BASE TABLE'
   AND c.table_name NOT IN (SELECT t FROM listadas);
SQL

pg -c "SELECT (SELECT count(*) FROM documentos)  AS documentos,
              (SELECT count(*) FROM movimientos) AS movimientos,
              (SELECT count(*) FROM sesiones)    AS sesiones,
              (SELECT count(*) FROM productos)   AS productos,
              (SELECT count(*) FROM formatos_documento) AS formatos,
              (SELECT count(*) FROM negocios)    AS negocios,
              (SELECT count(*) FROM usuarios)    AS usuarios;"

echo "Listo. Mandá los archivos."
