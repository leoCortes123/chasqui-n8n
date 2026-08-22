---
id: DOMAIN-PORTAL
type: domain
status: active
implemented_in: [db/actual/funciones/portal_*.sql, portal/Caddyfile, portal/publico/, bin/preparar-portal.sh]
---

# Portal (PostgREST + HTML estático)

**Propósito**: pantalla donde lo que no cabe en el chat se mira y se acciona.
Sin contraseñas: la identidad es Telegram vía token de un solo uso.

| | |
|---|---|
| **Entry points** | `POST /api/rpc/<funcion>` (única forma; no hay REST sobre tablas); `/portal` sirve HTML plano |
| **Entradas** | `p_token` (apertura) o `Authorization: Bearer <jwt>` (resto) |
| **Salidas** | `jsonb` siempre; error de negocio = `{ok:false,error}`; sin negocio = excepción `42501` → HTTP 403 |
| **Tablas primarias** | `portal_tokens`, y lectura sobre todas las del negocio |
| **Funciones primarias** | apertura: `portal_token_crear`(chat) → `portal_sesion_abrir`(anónima, firma JWT HS256 con secreto por GUC) · sesión: 27 funciones con GRANT a `portal_usuario`; `portal_claim`/`portal_negocio` internas |

**Contratos**: [`../contracts/rpc-portal.md`](../contracts/rpc-portal.md).
**Decisiones**: `PORTAL-001`, `BASE-001`, `PRODUCTO-002`.
**Invariantes**: INV-018.

## Superficie exacta `[CONFIRMADO]`

- A `portal_anon` (sin JWT): sólo `portal_sesion_abrir`, `portal_cotizacion_publica`.
- A `portal_usuario`: 27 `portal_*` (perfil/negocio, movimientos, productos,
  conteos, alias, cartera/pagos, conocimiento/pendientes, recomendaciones,
  pedido, snapshots, informes, cotizaciones).
- Sin GRANT (internas): `portal_claim`, `portal_negocio`, `portal_mov_nombre`,
  `portal_token_crear`.
- Roles de Postgres **sin ningún permiso sobre tablas** (`role_table_grants`=0).

## Flujo de identidad

```text
chat /portal → portal_token_crear(usuario, 15min): invalida anteriores,
               guarda SOLO sha256 → enlace …/portal/#t=<token>
navegador   → POST rpc portal_sesion_abrir {p_token}: un solo error
               'enlace_invalido' para inexistente/usado/vencido
               → JWT {role:'portal_usuario', usuario_id, negocio_id, exp:+12h}
cada rpc    → portal_claim('negocio_id') dentro de la función; NUNCA parámetro
```

## Lo que un agente suele romper

- Crear una función RPC sin `GRANT EXECUTE` explícito ni `NOTIFY pgrst` al final
  de la migración (PostgREST cachea el esquema) — INV-018.
- Aceptar `negocio_id` como parámetro: es un IDOR directo.
- Olvidar que el aislamiento depende del `WHERE negocio_id` de cada función:
  no hay RLS ni test que lo detecte (riesgo estructural registrado).
- Suponer expiración/revocación del JWT: no existe; emitido vale 12 h.
- Frontend: `portal/publico/index.html` (47 KB, sin build), `const API='/api'`,
  token llega en fragmento `#t=` (no viaja al servidor). Cotización pública:
  `cotizacion.html`.

Detalle completo: `../../agent-context/interfaces/api.md`, `../../agent-context/reference/seguridad.md`.
