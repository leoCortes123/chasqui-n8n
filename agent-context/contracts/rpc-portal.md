---
id: CONTRACT-RPC-PORTAL
type: contract
status: active
provider: funciones portal_* (Postgres SECURITY DEFINER)
consumers: [PostgREST, portal/publico/index.html, DOMAIN-PORTAL]
---

# RPC del portal (HTTP ↔ PostgREST ↔ SQL)

**Propósito**: única API HTTP. Todo es `POST /api/rpc/<funcion>`; el negocio se
deduce del JWT dentro de cada función (`PORTAL-001`).

## Apertura de sesión

```text
1. chat /portal → portal_token_crear(usuario_id, 15 min)
   · 24 bytes aleatorios hex · INVALIDA tokens anteriores
   · guarda SOLO digest(token,'sha256')
   → enlace {portal_url_base}/portal/#t=<token>  (fragmento: no viaja al server)
2. POST /api/rpc/portal_sesion_abrir {"p_token": "..."}
   · UPDATE usado_en WHERE hash ∧ no usado ∧ no vencido
   · error único {"ok":false,"error":"enlace_invalido"} (no discrimina causa)
   · firma JWT HS256 con current_setting('app.settings.jwt_secret')
     payload {role:'portal_usuario', usuario_id, negocio_id, exp:+12h}
3. resto: Authorization: Bearer <jwt>; PostgREST asume portal_usuario y expone
   request.jwt.claims → portal_claim('negocio_id') → portal_negocio() lanza 42501 si falta
```

## Reglas duras para toda función nueva

1. `negocio_id` NUNCA como parámetro — IDOR.
2. `GRANT EXECUTE` explícito a `portal_usuario` (o `portal_anon` sólo si es de
   apertura); los roles NO tienen permisos sobre tablas.
3. La migración que la crea/cambia termina en `NOTIFY pgrst` (cache de esquema).
4. Devuelve `jsonb`; fallo de negocio = `{ok:false,error}`; falta de negocio =
   excepción `42501` → 403.
5. Sin RLS: el aislamiento ES el `WHERE negocio_id` de tu función. Nada lo
   comprueba automáticamente.

## Límites y superficie

- `PGRST_DB_MAX_ROWS=1000`; OpenAPI deshabilitado.
- Expuestas: 2 anónimas + 27 de usuario. Internas sin GRANT:
  `portal_claim`, `portal_negocio`, `portal_mov_nombre`, `portal_token_crear`.
- Frontend: `index.html` sin build; `rpc(fn,args)` con fetch; JWT en memoria;
  pantalla cotización pública separada con su propio token.

## Tests

Ninguno automatizado (hueco declarado en agent-context/reference/pruebas.md). Verificación manual:
roles y GRANTs vía catálogo (`agent-context/reference/seguridad.md §2`) y flujo completo con un
token vivo.
