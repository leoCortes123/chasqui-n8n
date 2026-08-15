#!/usr/bin/env bash
# Exporta los workflows de n8n a workflows/ para versionarlos en git.
# No es por portabilidad: es porque reconstruirlos a mano tras perder un
# volumen es un día perdido.
set -euo pipefail

cd "$(dirname "$0")/.."

docker compose exec -T n8n rm -rf /tmp/wf
docker compose exec -T n8n n8n export:workflow --all --separate --pretty --output=/tmp/wf

rm -rf workflows
mkdir -p workflows
docker compose cp n8n:/tmp/wf/. workflows/
docker compose exec -T n8n rm -rf /tmp/wf

ls -1 workflows/
echo
echo "Las credenciales NO se exportan aquí: quedan cifradas con N8N_ENCRYPTION_KEY"
echo "y se recuperan restaurando el dump de la base '$N8N_DB' con esa misma clave."
