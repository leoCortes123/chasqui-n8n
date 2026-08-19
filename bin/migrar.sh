#!/usr/bin/env bash
# Instala o actualiza la base de negocio.
#
#   1. Si la base está vacía, aplica db/base/ — el Chasqui v0: esquema completo
#      más el contenido del sistema (plantillas, prompts, parámetros, servicios).
#      Reemplaza a las 73 migraciones que lo construyeron, archivadas en
#      docs/historico/migraciones/, y las sella como aplicadas.
#   2. Después aplica db/migraciones/*.sql, que arranca en la 074.
#
# Cada migración corre en una sola transacción junto con su registro: si falla,
# no queda a medias ni marcada como aplicada.
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

pg() {
  docker compose exec -T -e PGPASSWORD="$CHASQUI_DB_PASSWORD" postgres \
    psql -v ON_ERROR_STOP=1 -U "$CHASQUI_DB_USER" -d "$CHASQUI_DB" "$@"
}

# ── Base: sólo si la base está vacía ─────────────────────────────────────────
# El marcador es la tabla `negocios`: existe desde la primera línea del esquema.
if [ -z "$(pg -tAc "SELECT to_regclass('public.negocios')")" ]; then
  echo "Base vacía: instalando db/base/ (Chasqui v0)."
  for b in db/base/*.sql; do
    echo "  ->   $(basename "$b")"
    pg -q -1 < "$b"
  done
  echo "Chasqui v0 instalado."
fi

pg -q -c 'CREATE TABLE IF NOT EXISTS schema_migraciones (
            archivo     text PRIMARY KEY,
            aplicada_en timestamptz NOT NULL DEFAULT now()
          )' >/dev/null

shopt -s nullglob
for f in db/migraciones/*.sql; do
  nombre=$(basename "$f")
  if [ -n "$(pg -tAc "SELECT 1 FROM schema_migraciones WHERE archivo = '$nombre'")" ]; then
    echo "  ya   $nombre"
    continue
  fi
  echo "  ->   $nombre"
  {
    cat "$f"
    printf "\nINSERT INTO schema_migraciones (archivo) VALUES ('%s');\n" "$nombre"
  } | pg -q -1
done

echo "Migraciones al día."

# La fotografía del estado vigente se regenera acá y no a mano: si depende de
# que alguien se acuerde, se desactualiza, y db/actual/ desactualizado es peor
# que no tenerlo — vuelve a ser una fuente que miente.
# (-f y no -x: el repo vive en un montaje fuseblk donde chmod es un no-op y
# ningún script tiene bit de ejecución; todo se invoca con `bash bin/...`.)
if [ -f bin/gen_estado_sql.sh ]; then
  bash bin/gen_estado_sql.sh
  echo "Revisar 'git diff db/actual/': eso es lo que cambió de verdad."
fi
