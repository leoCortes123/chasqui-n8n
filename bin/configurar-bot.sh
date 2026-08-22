#!/usr/bin/env bash
# Configura el PERFIL del bot en Telegram: lo que se ve antes y alrededor de la
# conversación. Es idempotente y se corre a mano cuando cambian los textos o
# aparece un admin nuevo.
#
#   bash bin/configurar-bot.sh
#
# Qué deja puesto:
#
#   * la descripción larga: la pantalla "¿Qué puede hacer este bot?" que Telegram
#     muestra ANTES de que exista una conversación, con el botón Iniciar. Es el
#     primer contacto y se resuelve sin escribir nada;
#   * la descripción corta: la que sale en el perfil y en las búsquedas;
#   * el menú de comandos (el botón ☰ junto al campo de texto), en dos ámbitos:
#     el de todos, y uno por cada chat de admin con los comandos de operación
#     agregados. Un usuario común no ve /salud ni /embudo: no existen para él;
#   * el botón de menú en modo `commands`. Cuando el portal sea Mini App, este
#     es el lugar donde pasa a ser `web_app` (ver agent-context/product/telegram-ux.md).
#
# El menú de comandos es lo único de la conversación que Telegram no deja poner
# como botón dentro de un mensaje; todo lo demás se toca. Los comandos siguen
# existiendo escritos porque un botón y su comando son la misma ejecución en el
# router (migración 024).
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

: "${TELEGRAM_BOT_TOKEN:?falta TELEGRAM_BOT_TOKEN en .env}"

API="https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN"

# Llama a un método de la Bot API con un body JSON y falla si no responde ok.
llamar() {
  metodo="$1"; cuerpo="$2"
  r=$(curl -sf --max-time 20 -H 'Content-Type: application/json' \
        -d "$cuerpo" "$API/$metodo" 2>&1) || r='{"ok":false,"error":"fallo de red"}'
  case "$r" in
    *'"ok":true'*) echo "  ok    $metodo" ;;
    *) echo "  ERROR $metodo: $r" >&2; return 1 ;;
  esac
}

# --- Perfil ------------------------------------------------------------------
# short_description: hasta 120 caracteres. description: hasta 512.
llamar setMyShortDescription '{
  "short_description": "Convierto tus facturas y tus ventas en decisiones. Sin planillas y sin instalar nada."
}'

llamar setMyDescription '{
  "description": "Soy Chasqui y trabajo con vos en la administración de tu negocio.\n\nMe mandás lo que ya tenés (tus facturas de la DIAN, el archivo de ventas de tu sistema) y te devuelvo un informe corto y en español: qué te deja plata, qué costo se te subió y qué conviene revisar esta semana.\n\nTocá Iniciar y te muestro."
}'

# --- Comandos ----------------------------------------------------------------
# Ámbito de todos. Nada de comandos de operación acá.
USUARIO='[
  {"command":"nueva",       "description":"Empezar un análisis nuevo"},
  {"command":"listo",       "description":"Ya envié los archivos, analizar"},
  {"command":"cancelar",    "description":"Cancelar el análisis en curso"},
  {"command":"portal",      "description":"Abrir mi portal"},
  {"command":"plan",        "description":"Mi plan y mi consumo del mes"},
  {"command":"saber",       "description":"Enseñarme algo de tu negocio"},
  {"command":"comofunciona","description":"Cómo funciona Chasqui"},
  {"command":"privacidad",  "description":"Qué datos uso"},
  {"command":"ayuda",       "description":"Volver al inicio"}
]'

ADMIN='[
  {"command":"salud",   "description":"Estado del sistema"},
  {"command":"embudo",  "description":"Embudo de uso"},
  {"command":"fallas",  "description":"Últimas fallas"},
  {"command":"consumo", "description":"Consumo de tokens"},
  {"command":"matching","description":"Estado del matching de productos"},
  {"command":"pendientes","description":"Productos sin resolver y cuánta plata son"},
  {"command":"admin",   "description":"Resumen de operación"}
]'

llamar setMyCommands "{\"commands\": $USUARIO, \"scope\": {\"type\": \"default\"}}"

# Los chats de admin salen de la base, no de una variable de entorno: quién es
# admin ya está en `usuarios.rol` y no hay por qué mantenerlo en dos lados.
admins=$(docker compose exec -T -e PGPASSWORD="$CHASQUI_DB_PASSWORD" postgres \
  psql -qtA -U "$CHASQUI_DB_USER" -d "$CHASQUI_DB" -c \
  "SELECT DISTINCT chat_de_usuario(id) FROM usuarios
    WHERE rol = 'admin' AND chat_de_usuario(id) IS NOT NULL;" 2>/dev/null || true)

if [ -z "${admins//[[:space:]]/}" ]; then
  echo "  aviso: no hay chats de admin en la base; se omite el ámbito admin"
else
  # El ámbito de chat REEMPLAZA al de defecto, no se suma: la lista del admin
  # tiene que traer también los comandos de usuario.
  TODOS=$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]) + json.loads(sys.argv[2])))' \
          "$USUARIO" "$ADMIN")
  for chat in $admins; do
    llamar setMyCommands \
      "{\"commands\": $TODOS, \"scope\": {\"type\": \"chat\", \"chat_id\": $chat}}"
  done
fi

# --- Botón de menú -----------------------------------------------------------
llamar setChatMenuButton '{"menu_button": {"type": "commands"}}'

echo "Bot configurado."
