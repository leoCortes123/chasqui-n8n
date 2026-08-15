#!/usr/bin/env bash
# Importa a n8n los workflows generados por bin/gen_wf_*.py y los reactiva.
#
# Uso:  bash bin/importar-workflows.sh                 # todos
#       bash bin/importar-workflows.sh wf_ingesta      # solo esos
#
# Por qué republica: los generadores escriben "active": false, así que un import
# a secas apaga el workflow. Y en n8n 2.x "activo" y "publicado" son cosas
# distintas: el import crea una versión nueva y la deja SIN publicar
# (activeVersionId queda NULL). Poner active=true a mano en la base no alcanza
# —lo intenté y falla en silencio—: las llamadas a un sub-workflow resuelven la
# versión *publicada*, así que sin publicar, `Execute Workflow` no ejecuta nada.
# Y como esos nodos van con onError continueRegularOutput, el padre no se
# entera: el archivo se manda y nunca aparece una ejecución del hijo.
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

if [ "$#" -gt 0 ]; then
  archivos=()
  for n in "$@"; do archivos+=("workflows/${n%.json}.json"); done
else
  # Solo los generados (wf_*.json); los exportados van con nombre de id.
  shopt -s nullglob
  archivos=(workflows/wf_*.json)
fi

[ "${#archivos[@]}" -gt 0 ] || { echo "nada que importar"; exit 1; }

docker compose exec -T n8n rm -rf /tmp/imp
docker compose exec -T n8n mkdir -p /tmp/imp

ids=()
for f in "${archivos[@]}"; do
  echo "  -> $(basename "$f")"
  docker compose cp "$f" n8n:/tmp/imp/
  ids+=("$(python3 -c "import json,sys; print(json.load(open('$f'))['id'])")")
done

docker compose exec -T n8n n8n import:workflow --separate --input=/tmp/imp
docker compose exec -T n8n rm -rf /tmp/imp

# Publicar la versión recién importada y reactivar.
for id in "${ids[@]}"; do
  docker compose exec -T n8n n8n publish:workflow --id="$id" >/dev/null
  docker compose exec -T -e PGPASSWORD="$N8N_DB_PASSWORD" postgres \
    psql -qtA -U "$N8N_DB_USER" -d "$N8N_DB" \
    -c "UPDATE workflow_entity SET active = true WHERE id = '$id';" >/dev/null
  echo "  publicado y activo: $id"
done

docker compose restart n8n >/dev/null
echo "n8n reiniciado. Esperando que levante..."

# No alcanza con /healthz: responde OK antes de que n8n active los workflows, y
# durante esa ventana el webhook devuelve 404. Se espera a que el webhook real
# conteste cualquier cosa distinta de 404.
# El código se saca con sed y no con `awk '{print $2}'`: cuando el webhook no
# está listo, el wget de busybox contesta
#   wget: server returned error: HTTP/1.1 404 Not Found
# y ahí el segundo campo es "server", que no es 404 y daba el visto bueno de una.
ruta="${TELEGRAM_WEBHOOK_PATH:-telegram}"
for _ in $(seq 1 40); do
  codigo=$(docker compose exec -T n8n sh -c \
    "wget -qO- --post-data='{}' --header='Content-Type: application/json' \
     --server-response http://localhost:5678/webhook/$ruta 2>&1 \
     | sed -n 's#.*HTTP/[0-9.]* \([0-9][0-9][0-9]\).*#\1#p' | tail -1" 2>/dev/null || true)
  if [ "$codigo" = "200" ]; then
    echo "listo (webhook responde 200)."
    exit 0
  fi
  sleep 3
done
echo "el webhook siguió en 404 tras 120s; revisá 'docker compose logs n8n'" >&2
exit 1
