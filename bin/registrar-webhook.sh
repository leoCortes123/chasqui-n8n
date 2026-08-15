#!/bin/sh
# Mantiene registrado el webhook de Telegram apuntando a n8n.
#
# En local la URL del quick tunnel de cloudflared cambia en cada reinicio, así
# que este servicio la descubre y re-registra sola. En la nube se fija
# WEBHOOK_URL al dominio real y este contenedor no se levanta (perfil `local`).
set -eu

command -v curl >/dev/null 2>&1 || apk add --no-cache curl >/dev/null 2>&1
# psql para escribirle a la base la URL pública del momento (la usa /portal).
command -v psql >/dev/null 2>&1 || apk add --no-cache postgresql-client >/dev/null 2>&1

: "${TELEGRAM_BOT_TOKEN:?falta TELEGRAM_BOT_TOKEN}"
: "${TELEGRAM_WEBHOOK_SECRET:?falta TELEGRAM_WEBHOOK_SECRET}"
RUTA="${TELEGRAM_WEBHOOK_PATH:-telegram}"

descubrir_url() {
  # Con WEBHOOK_URL fija no hay nada que descubrir.
  if [ -n "${WEBHOOK_URL:-}" ]; then
    echo "$WEBHOOK_URL"
    return 0
  fi
  # cloudflared publica el hostname del quick tunnel en su puerto de métricas.
  host=$(curl -sf --max-time 5 http://cloudflared:2000/quicktunnel 2>/dev/null \
         | sed -n 's/.*"hostname"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -n "$host" ] && echo "https://$host"
}

# WhatsApp (Cloud API): la suscripción del webhook vive en la APP de Meta y se
# re-apunta por la Graph API con el app access token (app_id|app_secret). Meta
# verifica la URL con un GET al momento, así que wf_wa_router tiene que estar
# importado y activo, o la llamada falla y se reintenta al minuto.
registrar_wa() {
  base_wa="$1"
  [ -n "${WA_APP_ID:-}" ] && [ -n "${WA_APP_SECRET:-}" ] && [ -n "${WA_VERIFY_TOKEN:-}" ] || return 0
  destino_wa="$base_wa/webhook/${WA_WEBHOOK_PATH:-whatsapp}"
  [ "$destino_wa" != "${anterior_wa:-}" ] || return 0

  echo "[registrador] whatsapp: registrando $destino_wa"
  r=$(curl -sf --max-time 20 -X POST \
    --data-urlencode "object=whatsapp_business_account" \
    --data-urlencode "callback_url=$destino_wa" \
    --data-urlencode "verify_token=$WA_VERIFY_TOKEN" \
    --data-urlencode "fields=messages" \
    --data-urlencode "access_token=${WA_APP_ID}|${WA_APP_SECRET}" \
    "https://graph.facebook.com/v23.0/${WA_APP_ID}/subscriptions" 2>&1) || r="fallo de red"

  case "$r" in
    *'"success":true'*)
      echo "[registrador] whatsapp: ok"
      anterior_wa="$destino_wa"
      # Suscribir la WABA a la app: idempotente, solo hace falta una vez pero
      # repetirla no molesta y así no hay paso manual.
      if [ -n "${WA_WABA_ID:-}" ] && [ -n "${WA_ACCESS_TOKEN:-}" ]; then
        curl -sf --max-time 15 -X POST \
          -H "Authorization: Bearer $WA_ACCESS_TOKEN" \
          "https://graph.facebook.com/v23.0/${WA_WABA_ID}/subscribed_apps" >/dev/null 2>&1 \
          && echo "[registrador] whatsapp: WABA suscrita a la app" \
          || echo "[registrador] whatsapp: aviso: no pude suscribir la WABA"
      fi
      ;;
    *)
      echo "[registrador] whatsapp ERROR: $r"
      ;;
  esac
}

anterior=""
anterior_wa=""
while true; do
  base=$(descubrir_url || true)

  if [ -z "$base" ]; then
    echo "[registrador] sin URL todavía (¿cloudflared arrancando?), reintento en 10s"
    sleep 10
    continue
  fi

  destino="$base/webhook/$RUTA"

  if [ "$destino" != "$anterior" ]; then
    echo "[registrador] registrando $destino"
    respuesta=$(curl -sf --max-time 15 \
      -d "url=$destino" \
      -d "secret_token=$TELEGRAM_WEBHOOK_SECRET" \
      -d "drop_pending_updates=true" \
      -d 'allowed_updates=["message","edited_message","callback_query"]' \
      "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/setWebhook" 2>&1) || respuesta="fallo de red"

    case "$respuesta" in
      *'"ok":true'*)
        echo "[registrador] ok"
        anterior="$destino"

        # La URL base del portal. El enlace de /portal se arma en SQL, y esta
        # es la única parte del sistema que sabe cómo se llama el túnel hoy.
        if [ -n "${PGHOST:-}" ]; then
          psql -v ON_ERROR_STOP=1 -qtA \
            -c "UPDATE parametros SET valor = to_jsonb('$base'::text)
                 WHERE clave = 'portal_url_base' AND negocio_id IS NULL;" \
            >/dev/null 2>&1 \
            && echo "[registrador] portal_url_base = $base" \
            || echo "[registrador] aviso: no pude escribir portal_url_base"
        fi

        # El menú de comandos y el perfil del bot se configuran con
        # bin/configurar-bot.sh, que además separa por ámbito (los comandos de
        # admin solo existen en los chats de admin). Acá se hacía a secas y en
        # cada reconexión del túnel, así que pisaba esa separación.
        ;;
      *)
        echo "[registrador] ERROR: $respuesta"
        ;;
    esac
  fi

  registrar_wa "$base"

  sleep 60
done
