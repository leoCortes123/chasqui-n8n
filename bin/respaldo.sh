#!/usr/bin/env bash
# Respaldo diario. La base ES la herramienta entera: sin ella no hay sesiones,
# ni servicios, ni textos, ni prompts, ni los archivos originales (van en bytea).
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

DESTINO=${1:-respaldos}
mkdir -p "$DESTINO"
FECHA=$(date +%Y%m%d-%H%M)

volcar() {
  local base=$1 usuario=$2 clave=$3
  docker compose exec -T -e PGPASSWORD="$clave" postgres \
    pg_dump -U "$usuario" -d "$base" --format=custom \
    > "$DESTINO/$base-$FECHA.dump"
  echo "  $DESTINO/$base-$FECHA.dump"
}

volcar "$CHASQUI_DB" "$CHASQUI_DB_USER" "$CHASQUI_DB_PASSWORD"
volcar "$N8N_DB"     "$N8N_DB_USER"     "$N8N_DB_PASSWORD"

# 14 días de retención local.
find "$DESTINO" -name '*.dump' -mtime +14 -delete

echo "Restaurar con: pg_restore --clean --if-exists -U <usuario> -d <base> <archivo>"
