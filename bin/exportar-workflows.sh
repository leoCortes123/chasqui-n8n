#!/usr/bin/env bash
# Exporta los workflows de n8n a workflows/ para versionarlos en git.
# No es por portabilidad: es porque reconstruirlos a mano tras perder un
# volumen es un día perdido.
#
# En workflows/ conviven DOS cosas y no son lo mismo:
#
#   wf_<nombre>.json   — lo que ESCRIBEN los generadores (bin/gen_wf_*.py).
#                        Es la fuente: bin/importar-workflows.sh lee estos.
#   wf<Id>.json        — lo que EXPORTA n8n. Es una foto del estado real,
#                        para poder reconstruir tras perder el volumen.
#
# Hasta la 057 este script hacía `rm -rf workflows` y se llevaba puestos los
# generados, dejando a importar-workflows.sh sin nada que importar. Ahora borra
# solo las fotos anteriores.
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

docker compose exec -T n8n rm -rf /tmp/wf
docker compose exec -T n8n n8n export:workflow --all --separate --pretty --output=/tmp/wf

mkdir -p workflows
# Solo las fotos: los wf_*.json de los generadores no se tocan.
find workflows -maxdepth 1 -name '*.json' ! -name 'wf_*.json' -delete
docker compose cp n8n:/tmp/wf/. workflows/
docker compose exec -T n8n rm -rf /tmp/wf

ls -1 workflows/
echo
echo "Las credenciales NO se exportan aquí: quedan cifradas con N8N_ENCRYPTION_KEY"
echo "y se recuperan restaurando el dump de la base '${N8N_DB:-n8n}' con esa misma clave."
