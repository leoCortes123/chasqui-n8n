#!/usr/bin/env bash
# Exporta los workflows de n8n a workflows/ para versionarlos en git.
# No es por portabilidad: es porque reconstruirlos a mano tras perder un
# volumen es un día perdido.
#
# Son DOS cosas distintas y desde 2026-08-18 viven en directorios separados:
#
#   workflows/wf_<nombre>.json   — lo que ESCRIBEN los generadores
#                                  (bin/gen_wf_*.py). Es la FUENTE:
#                                  bin/importar-workflows.sh lee estos.
#   workflows/fotos/wf<Id>.json  — lo que EXPORTA n8n. Es una foto del estado
#                                  real, para reconstruir tras perder el
#                                  volumen. NO es fuente de nada.
#
# Estaban mezclados en el mismo directorio y era el mismo problema que
# db/migraciones vs db/actual: catorce archivos donde sólo siete mandan, y las
# fotos quedándose atrás (15 de agosto contra generadores del 17). Quien
# buscara "el workflow del router" encontraba dos y podía leer el que no era.
#
# Hasta la 057 este script hacía `rm -rf workflows` y se llevaba puestos los
# generados, dejando a importar-workflows.sh sin nada que importar.
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

docker compose exec -T n8n rm -rf /tmp/wf
docker compose exec -T n8n n8n export:workflow --all --separate --pretty --output=/tmp/wf

mkdir -p workflows/fotos
# Solo las fotos anteriores: los wf_*.json de los generadores no se tocan.
find workflows/fotos -maxdepth 1 -name '*.json' -delete
docker compose cp n8n:/tmp/wf/. workflows/fotos/
docker compose exec -T n8n rm -rf /tmp/wf

ls -1 workflows/fotos/
echo
echo "Las credenciales NO se exportan aquí: quedan cifradas con N8N_ENCRYPTION_KEY"
echo "y se recuperan restaurando el dump de la base '${N8N_DB:-n8n}' con esa misma clave."
