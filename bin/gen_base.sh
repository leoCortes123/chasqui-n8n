#!/usr/bin/env bash
# Genera db/base/ — el Chasqui v0: una sola foto instalable del sistema actual.
#
# POR QUÉ EXISTE
#
# Chasqui pasó por varias reestructuraciones sin un orden previo, así que las
# migraciones se acumularon en capas: 73 archivos, 23.833 líneas, 263
# definiciones de función para 163 nombres. Leer eso para entender el sistema es
# leer todas las versiones que tuvo, no la que es. El esquema real cabe en 11.627
# líneas: menos de la mitad.
#
# EL DETALLE QUE NO ES NEGOCIABLE
#
# En Chasqui el comportamiento vive en filas. Un volcado de esquema a secas
# produce un sistema que arranca, no responde nada y no tiene servicios. El
# baseline incluye las tablas de CONTENIDO —plantillas, prompts, parámetros,
# sinónimos, intenciones, servicios, formatos— porque son el producto, no datos.
#
# Los datos de negocio (movimientos, documentos, facturas, negocios, usuarios)
# NO entran: son de quien opera la instalación.
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

DESTINO=db/base

# El producto. Orden de carga respetando las claves foráneas.
# QUÉ ES CONTENIDO Y QUÉ ES DATO
#
# El criterio no es el nombre ni el número de filas: es si la tabla tiene una
# columna de pertenencia (negocio_id, usuario_id, sesion_id, chat_id). Si la
# tiene, las filas son de quien opera la instalación. Si no, son del producto.
#
# Se comprueba con:
#   SELECT c.relname, EXISTS (SELECT 1 FROM pg_attribute a
#     WHERE a.attrelid=c.oid AND a.attname IN
#           ('negocio_id','usuario_id','sesion_id','chat_id'))
#     FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
#    WHERE n.nspname='public' AND c.relkind='r';
#
# `parametros` tiene negocio_id pero sus 34 filas son globales (negocio_id NULL):
# son los umbrales del producto. Si algún día hay parámetros por negocio, esta
# lista tiene que filtrarlos.
#
# Este criterio salió de un error: metricas_resultado quedó fuera en el primer
# intento por su nombre y sus 11 filas, y dos pruebas de aceptación fallaron
# contra la base recreada. Define qué métrica mide cada regla — es producto.
#
# El orden importa: servicios_entradas referencia formatos_documento y servicios.
CONTENIDO=(tipos_negocio modulos formatos_documento servicios servicios_entradas
           sinonimos_columna parametros plantillas prompts prompts_tecnicos
           intenciones metricas_resultado)

pg() {
  docker compose exec -T -e PGPASSWORD="$CHASQUI_DB_PASSWORD" postgres \
    psql -v ON_ERROR_STOP=1 -qtAX -U "$CHASQUI_DB_USER" -d "$CHASQUI_DB" "$@"
}
dump() {
  docker compose exec -T -e PGPASSWORD="$CHASQUI_DB_PASSWORD" postgres \
    pg_dump -U "$CHASQUI_DB_USER" -d "$CHASQUI_DB" "$@"
}
limpiar() {
  # Se quitan las líneas que pg_dump emite con datos de entorno o con tokens
  # aleatorios por volcado (\restrict de PG 18): romperían el determinismo.
  #
  # Sin `cat -s` a propósito: colapsar líneas en blanco repetidas parece
  # cosmético, pero los cuerpos de función van literales en el volcado y una
  # línea menos ahí es código distinto. La puerta de verificación lo detectó en
  # recomendaciones_registrar.
  grep -vE '^(--|SET |SELECT pg_catalog\.|\\(un)?restrict )'
}

formatos_semilla() {
  # `formatos_documento` es la única tabla de contenido que mezcla producto y
  # dato: las tres semillas las instaló una migración, pero los `tabular_%` los
  # APRENDIÓ el sistema de los archivos que subió un negocio (migración 017) y
  # su `mapeo` describe el POS de ese cliente, no el producto. Sin este filtro
  # el baseline instalaba el layout del POS de un cliente en toda base nueva.
  #
  # El criterio mecánico de arriba —columna de pertenencia— no los ve, porque la
  # tabla no tiene negocio_id: un formato aprendido se comparte entre negocios a
  # propósito. El discriminador está en la propia fila: `origen`.
  #
  # Por qué no se filtra el volcado de pg_dump con grep/awk: un INSERT de
  # --column-inserts ocupa varias líneas cuando un valor trae saltos (las
  # plantillas los traen), y cortar por línea deja SQL roto. Acá los INSERT se
  # arman con format(): la lista de columnas sale del catálogo, así que una
  # columna nueva entra sola y no hay nada que mantener sincronizado a mano.
  local cols marcas
  cols=$(pg -c "SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum)
                  FROM pg_attribute
                 WHERE attrelid = 'public.formatos_documento'::regclass
                   AND attnum > 0 AND NOT attisdropped")
  marcas=$(pg -c "SELECT string_agg('%L', ', ')
                    FROM pg_attribute
                   WHERE attrelid = 'public.formatos_documento'::regclass
                     AND attnum > 0 AND NOT attisdropped")
  pg -c "SELECT format('INSERT INTO public.formatos_documento ($cols) VALUES ($marcas);', $cols)
           FROM formatos_documento WHERE origen = 'semilla' ORDER BY codigo"
}

parametros_sin_entorno() {
  # `parametros` es producto —umbrales, ventanas, horarios— con UNA fila que no
  # lo es: `portal_url_base`, la URL pública del momento. La escribe
  # bin/registrar-webhook.sh cada vez que cloudflared levanta un túnel nuevo, y
  # el volcado la horneaba en el baseline: toda instalación nueva nacía con el
  # túnel efímero de la máquina donde se generó v0.
  #
  # No es cosmético. `router_portal` sólo responde `portal.sin_url` cuando el
  # valor está VACÍO; con una URL muerta manda el enlace igual, y ese enlace
  # lleva el token de sesión del portal en el fragmento. Un quick tunnel de
  # Cloudflare es un subdominio reciclable: si alguien lo toma, recibe tokens de
  # instalaciones ajenas. El baseline la emite vacía, que es el caso que el
  # código ya sabe manejar, y bin/preparar-portal.sh la llena con WEBHOOK_URL.
  local cols marcas exprs
  cols=$(pg -c "SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum)
                  FROM pg_attribute WHERE attrelid = 'public.parametros'::regclass
                   AND attnum > 0 AND NOT attisdropped")
  marcas=$(pg -c "SELECT string_agg('%L', ', ')
                    FROM pg_attribute WHERE attrelid = 'public.parametros'::regclass
                     AND attnum > 0 AND NOT attisdropped")
  exprs=$(pg -c "SELECT string_agg(CASE WHEN attname = 'valor'
                                        THEN 'CASE WHEN clave = ''portal_url_base''
                                                   THEN ''\"\"''::jsonb ELSE valor END'
                                        ELSE quote_ident(attname) END, ', ' ORDER BY attnum)
                   FROM pg_attribute WHERE attrelid = 'public.parametros'::regclass
                    AND attnum > 0 AND NOT attisdropped")
  pg -c "SELECT format('INSERT INTO public.parametros ($cols) VALUES ($marcas);', $exprs)
           FROM parametros ORDER BY negocio_id NULLS FIRST, clave"
}

if ! docker compose ps --status running --services 2>/dev/null | grep -qx postgres; then
  echo "ERROR: postgres no está corriendo. 'docker compose up -d' (nunca down)." >&2
  exit 1
fi

# ── El freno: regenerar no es rebasar ────────────────────────────────────────
#
# Este script vuelca el catálogo VIVO. Si la base tiene migraciones aplicadas
# por encima del baseline, regenerar las absorbe y vuelve a sellar: v0 pasa a
# ser otro, y `db/migraciones/` queda con archivos que toda instalación nueva se
# saltaría. Eso puede ser lo que se quiere —rebasar— pero nunca como efecto
# colateral de corregir el generador, que es como pasó la primera vez.
#
# Por defecto se exige que la base esté exactamente en v0. Rebasar se pide.
REBASAR=0
[ "${1:-}" = "--rebasar" ] && REBASAR=1

if [ "$REBASAR" -eq 0 ] && [ -f "$DESTINO/002_sellar.sql" ]; then
  SOBRANTES=$(pg -c "SELECT string_agg(archivo, ' ' ORDER BY archivo)
                       FROM schema_migraciones" \
              | tr ' ' '\n' | grep -v '^$' | while read -r m; do
                  grep -q "('${m}')" "$DESTINO/002_sellar.sql" || echo "$m"
                done)
  if [ -n "$SOBRANTES" ]; then
    echo "ERROR: la base está por delante del baseline. Regenerar ahora lo" >&2
    echo "       rebasaría, absorbiendo y sellando:" >&2
    echo "$SOBRANTES" | sed 's/^/         /' >&2
    echo "       Si es lo que querés: bash bin/gen_base.sh --rebasar" >&2
    echo "       Si no: regenerá con la base instalada sólo desde db/base/." >&2
    exit 1
  fi
fi

mkdir -p "$DESTINO"

# ── 000: el esquema ──────────────────────────────────────────────────────────
{
  cat <<'ENC'
-- 000_esquema.sql — el esquema completo de Chasqui v0.
--
-- GENERADO por bin/gen_base.sh desde el catálogo vivo. No editar a mano.
--
-- Reemplaza a las 73 migraciones que lo construyeron, archivadas en
-- agent-context/history/migraciones/. El porqué de cada pieza vive ahora en
-- decisiones/; el qué existe, en db/actual/INDICE.md.
--
-- Las extensiones (pgcrypto, pg_trgm, unaccent) las instala db/init/00_bases.sh
-- con el superusuario, igual que antes: el dueño de la base no siempre puede.
--
-- check_function_bodies: pg_dump emite las funciones antes que las tablas, y las
-- de LANGUAGE sql validan su cuerpo al crearse. Sin esto, la primera que consulte
-- una tabla que todavía no existe aborta el archivo entero.
SET check_function_bodies = false;
ENC
  echo
  dump --schema-only --no-owner --no-comments | limpiar
} > "$DESTINO/000_esquema.sql"

# ── 001: el contenido ────────────────────────────────────────────────────────
{
  cat <<'ENC'
-- 001_contenido.sql — el comportamiento de Chasqui, que vive en filas.
--
-- GENERADO por bin/gen_base.sh. No editar a mano: se cambia por migración y se
-- regenera.
--
-- Sin esto el sistema arranca, no responde nada y no tiene servicios. No son
-- datos de ejemplo: son el producto. Los datos de negocio (movimientos,
-- documentos, facturas, negocios, usuarios) NO están acá y no deben estarlo.
ENC
  echo
  for t in "${CONTENIDO[@]}"; do
    if [ "$t" = formatos_documento ]; then
      formatos_semilla
      echo
    elif [ "$t" = parametros ]; then
      parametros_sin_entorno
      echo
    else
      dump --data-only --no-owner --column-inserts -t "public.$t" | limpiar
    fi
  done
} > "$DESTINO/001_contenido.sql"

# ── 002: sellar ──────────────────────────────────────────────────────────────
{
  cat <<'ENC'
-- 002_sellar.sql — deja constancia de que el esquema ya trae las 73 migraciones.
--
-- GENERADO por bin/gen_base.sh. Sin esto, una base creada desde el baseline
-- creería que le faltan 73 migraciones; con esto, bin/migrar.sh sabe que la
-- primera pendiente es la 074.
ENC
  echo
  echo "CREATE TABLE IF NOT EXISTS schema_migraciones ("
  echo "  archivo     text PRIMARY KEY,"
  echo "  aplicada_en timestamptz NOT NULL DEFAULT now());"
  echo
  echo "INSERT INTO schema_migraciones (archivo) VALUES"
  pg -c "SELECT string_agg(format('  (%L)', archivo), E',\n' ORDER BY archivo) FROM schema_migraciones"
  echo "ON CONFLICT (archivo) DO NOTHING;"
} > "$DESTINO/002_sellar.sql"

echo "db/base/ generado:"
wc -l "$DESTINO"/*.sql | sed 's/^/  /'
