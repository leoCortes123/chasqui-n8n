#!/usr/bin/env bash
# Aplica db/migraciones/*.sql en orden sobre la base de negocio.
# Cada migración corre en una sola transacción junto con su registro: si falla,
# no queda a medias ni marcada como aplicada.
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

pg() {
  docker compose exec -T -e PGPASSWORD="$CHASQUI_DB_PASSWORD" postgres \
    psql -v ON_ERROR_STOP=1 -U "$CHASQUI_DB_USER" -d "$CHASQUI_DB" "$@"
}

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
