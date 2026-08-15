#!/bin/bash
# Corre UNA sola vez, en el primer arranque del volumen de Postgres.
# Crea las dos bases separadas: negocio y runtime de n8n.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-SQL
	CREATE ROLE ${CHASQUI_DB_USER} LOGIN PASSWORD '${CHASQUI_DB_PASSWORD}';
	CREATE DATABASE ${CHASQUI_DB} OWNER ${CHASQUI_DB_USER};

	CREATE ROLE ${N8N_DB_USER} LOGIN PASSWORD '${N8N_DB_PASSWORD}';
	CREATE DATABASE ${N8N_DB} OWNER ${N8N_DB_USER};
SQL

# Las extensiones las instala el superusuario; el dueño de la base no siempre
# puede. Se hacen aquí, una vez, y las migraciones ya las dan por hechas.
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$CHASQUI_DB" <<-SQL
	CREATE EXTENSION IF NOT EXISTS pgcrypto;
	CREATE EXTENSION IF NOT EXISTS pg_trgm;
	CREATE EXTENSION IF NOT EXISTS unaccent;
SQL

echo "Bases ${CHASQUI_DB} y ${N8N_DB} creadas."
