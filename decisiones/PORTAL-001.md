---
id: PORTAL-001
dominio: portal
estado: vigente
fecha: 2026-07-26
titulo: Ninguna función es pública por defecto y el negocio sale del JWT
invariantes:
  - el rol de PostgREST no tiene permiso sobre ninguna tabla
  - lo único ejecutable desde HTTP son las funciones portal_*, con GRANT explícito una por una
  - el negocio_id sale siempre del JWT, nunca de un parámetro de la petición
  - toda migración que cree o cambie una función RPC termina en NOTIFY pgrst
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: [PRODUCTO-002]
implementada_en: [docs/historico/migraciones/033_portal.sql]
afecta: [portal_negocio, portal_informe, portal_recomendaciones, jwt_firmar]
procedencia: docs/GUIA_TECNICA.md §5.10 y §12; lecciones rescatadas de la memoria de Claude (decisiones/candidatos/desde_memoria/portal-chasqui-postgrest.md y default-privileges-y-cache-postgrest.md) el 2026-08-18
---

## Problema medido

PostgREST publica la base entera si se le deja. Y `ALTER DEFAULT PRIVILEGES IN
SCHEMA` no quita el `EXECUTE` que Postgres concede a `PUBLIC` en toda función
nueva: creer que lo quita deja funciones expuestas sin que nadie lo note.

Además, una función que reciba `negocio_id` como parámetro es un IDOR: cualquiera
con un token válido lee el negocio de otro cambiando un número.

## Decisión

Sin permisos sobre tablas. `GRANT EXECUTE` explícito, función por función, sólo
para las `portal_*`. El `negocio_id` se extrae del JWT dentro de la función.
Toda migración con RPC termina en `NOTIFY pgrst` porque PostgREST cachea el
esquema y si no, la función nueva no existe para el mundo.

## Alternativas descartadas

RLS. Congelada en CORE-004: con cero permisos sobre tablas no hay superficie que
proteger con políticas, y agrega una capa que hay que razonar en cada consulta.

## Consecuencias

`bin/verificar.sh` chequea que las funciones nuevas traigan `GRANT` y que la
migración termine en `NOTIFY pgrst`.
