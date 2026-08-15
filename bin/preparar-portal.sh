#!/usr/bin/env bash
# Crea los roles de PostgREST. Corre como SUPERUSUARIO: CREATE ROLE no está al
# alcance del dueño de la base, así que esto no puede ser una migración.
#
# Orden en una instalación nueva:
#   bash bin/preparar-portal.sh      # roles (esto)
#   bash bin/migrar.sh               # el resto, incluida la 033
#   docker compose up -d
#
# Es idempotente: se puede volver a correr para rotar la contraseña.
#
# Los tres roles y por qué son tres:
#   authenticator   se conecta PostgREST. NOINHERIT y sin privilegios propios:
#                   lo único que puede hacer es SET ROLE a los otros dos.
#   portal_anon     visitante sin sesión. Solo portal_sesion_abrir.
#   portal_usuario  sesión abierta. Solo las RPC portal_*.
# Los GRANT los da la migración 033, que es donde están las funciones.
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

: "${PORTAL_DB_PASSWORD:?falta PORTAL_DB_PASSWORD en .env}"

su() {
  docker compose exec -T -e PGPASSWORD="$POSTGRES_SUPERUSER_PASSWORD" postgres \
    psql -v ON_ERROR_STOP=1 -qtA -U "$POSTGRES_SUPERUSER" "$@"
}

su -d postgres <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
    CREATE ROLE authenticator LOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'portal_anon') THEN
    CREATE ROLE portal_anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'portal_usuario') THEN
    CREATE ROLE portal_usuario NOLOGIN;
  END IF;
END
\$\$;

ALTER ROLE authenticator WITH LOGIN NOINHERIT PASSWORD '${PORTAL_DB_PASSWORD}';
GRANT portal_anon, portal_usuario TO authenticator;
SQL

# CONNECT sobre la base de negocio; nada más. Todo lo demás lo da la 033.
su -d "$CHASQUI_DB" -c "GRANT CONNECT ON DATABASE \"$CHASQUI_DB\" TO authenticator;"

echo "roles listos: authenticator, portal_anon, portal_usuario"

# En la nube WEBHOOK_URL está fija y no hay registrador que descubra nada, así
# que la URL del portal se siembra acá. En local queda vacía y la escribe el
# registrador con la del túnel del momento.
if [ -n "${WEBHOOK_URL:-}" ]; then
  docker compose exec -T -e PGPASSWORD="$CHASQUI_DB_PASSWORD" postgres \
    psql -v ON_ERROR_STOP=1 -qtA -U "$CHASQUI_DB_USER" -d "$CHASQUI_DB" \
    -c "UPDATE parametros SET valor = to_jsonb('${WEBHOOK_URL%/}'::text)
         WHERE clave = 'portal_url_base' AND negocio_id IS NULL;" >/dev/null \
    && echo "portal_url_base = ${WEBHOOK_URL%/}"
fi
