# Interfaces HTTP

Todo lo público pasa por Caddy. `[CONFIRMADO]` `portal/Caddyfile`:

| Ruta | Destino | Nota |
|---|---|---|
| `/webhook/*`, `/webhook-test/*` | `n8n:5678` | la ruta exacta la fija `TELEGRAM_WEBHOOK_PATH` / `WA_WEBHOOK_PATH` |
| `/api/*` | `postgrest:3000`, con `uri strip_prefix /api` | PostgREST espera `/rpc/...` en la raíz |
| `/portal`, `/portal/*` | `/srv` (= `portal/publico/`) | HTML estático |
| cualquier otra | `respond "no encontrado" 404` | un 404 seco no delata que detrás hay n8n |

---

## 1. Webhooks

### Telegram

| | |
|---|---|
| Método y ruta | `POST /webhook/<TELEGRAM_WEBHOOK_PATH>` |
| Autenticación | cabecera `X-Telegram-Bot-Api-Secret-Token`, comparada contra el secreto **embebido en el nodo al generar** |
| Respuesta | `200` inmediato (`responseMode: onReceived`), cuerpo vacío |
| Rechazo | `return []` — sin código de error, sin registro. Un atacante no distingue éxito de rechazo |
| Payload | update estándar de Telegram: `message`, `edited_message`, `callback_query` |

Se extrae: `from.id`, `from.username`, `chat.id`, texto (`message.text` ‖
`callback_query.data` ‖ `caption`), `document`/`photo`, `callback_query.id`,
`callback_query.message.message_id`.

### WhatsApp

| | |
|---|---|
| Verificación | `GET /webhook/<WA_WEBHOOK_PATH>?hub.mode=subscribe&hub.verify_token=…&hub.challenge=…` → devuelve el challenge en texto plano, o `403` |
| Mensajes | `POST` misma ruta, `200` inmediato |
| Autenticación | **ninguna criptográfica**. Ruta secreta + descarte si `value.metadata.phone_number_id ≠ WA_PHONE_NUMBER_ID` |
| Payload | `entry[].changes[].value.messages[]`; un item de salida por mensaje |

`[CONFIRMADO]` `WA_PHONE_NUMBER_ID` está **vacío** en `.env`, así que la
comparación se salta (`if (PNID && ...)`) y **todo** update pasaría el filtro.
Al mismo tiempo, las URLs de envío quedaron como
`https://graph.facebook.com/v23.0//messages`. Canal generado, no operativo.

---

## 2. API del portal (PostgREST)

`[CONFIRMADO]` No hay endpoints REST sobre tablas. **Todo** es `POST
/api/rpc/<funcion>` con cuerpo JSON de parámetros.

### Autenticación

```
1. En el chat: /portal  ->  router_portal
      portal_token_crear(usuario, 15 min)
        - genera 24 bytes aleatorios en hex
        - INVALIDA los tokens anteriores del mismo usuario
        - guarda SOLO digest(token,'sha256')
      responde el enlace  <portal_url_base>/portal/#t=<token>

2. En el navegador: POST /api/rpc/portal_sesion_abrir {p_token}
      - UPDATE portal_tokens SET usado_en=now()
        WHERE hash=digest(token) AND usado_en IS NULL AND expira_en > now()
      - si no matchea: {"ok":false,"error":"enlace_invalido"}
        (un solo mensaje para "no existe", "ya se usó" y "venció")
      - si matchea: firma un JWT HS256 con jwt_firmar(payload, secreto)
        payload = {role:'portal_usuario', usuario_id, negocio_id, exp: +12 h}
        el secreto sale de current_setting('app.settings.jwt_secret')
        (PGRST_APP_SETTINGS_JWT_SECRET; no se guarda en la base)

3. Todas las demás llamadas: Authorization: Bearer <jwt>
      PostgREST asume el rol 'portal_usuario' y expone request.jwt.claims
      portal_claim('negocio_id') -> portal_negocio() -> el negocio de la sesión
```

`[CONFIRMADO]` `PORTAL-001` invariante 3 se cumple: **ninguna** función
`portal_*` acepta `negocio_id` como parámetro. Sale siempre del JWT.

### Funciones expuestas

`[CONFIRMADO]`, leído de `has_function_privilege`:

**A `portal_anon` (sin JWT), 2:**

| Función | Parámetros | Devuelve |
|---|---|---|
| `portal_sesion_abrir` | `p_token text` | `{ok, jwt, expira}` o `{ok:false, error}` |
| `portal_cotizacion_publica` | `p_token text` | cotización para el cliente final |

**A `portal_usuario` (con JWT), 27:**

| Grupo | Funciones |
|---|---|
| Perfil y negocio | `portal_perfil`, `portal_negocio_guardar(p_nit)` |
| Movimientos | `portal_movimientos(p_tipo, p_limite)`, `portal_movimientos_resumen`, `portal_documentos(p_limite)` |
| Productos e inventario | `portal_productos`, `portal_conteos(p_limite)`, `portal_conteo_guardar(p_producto_id, p_unidades, p_fecha)` |
| Matching | `portal_alias_pendientes(p_limite)`, `portal_alias_confirmar(p_alias_id, p_producto_id)` |
| Cartera | `portal_cartera`, `portal_factura_guardar(...)`, `portal_pago_registrar(p_factura_id, p_valor, p_fecha, p_medio)` |
| Conocimiento | `portal_conocimiento(p_tipo)`, `portal_conocimiento_guardar(...)`, `portal_conocimiento_borrar(p_id)`, `portal_pendientes` |
| Inteligencia | `portal_recomendaciones(p_limite)`, `portal_recomendacion_accion(p_id, p_accion)`, `portal_pedido`, `portal_snapshots(p_limite)`, `portal_informes(p_limite)`, `portal_informe(p_id)` |
| Cotizador | `portal_cotizaciones(p_limite)`, `portal_cotizacion_guardar(...)`, `portal_cotizacion_revocar(p_id)`, `portal_cotizacion_publica` |

**No expuestas** (existen pero sin GRANT): `portal_claim`, `portal_negocio`,
`portal_mov_nombre`, `portal_token_crear`.

`[CONFIRMADO]` Hay 32 funciones `portal_*`. Las **28** expuestas (27 a
`portal_usuario` + `portal_sesion_abrir` a `portal_anon`; `portal_cotizacion_publica`
está en las dos listas) son todas `SECURITY DEFINER`; las 4 internas no lo son
—`portal_claim` y `portal_negocio` tienen que correr con el rol de la petición
para leer `request.jwt.claims`—.

### Formato de respuesta

`[CONFIRMADO]` Todas devuelven `jsonb`. PostgREST lo entrega como cuerpo JSON.
`PGRST_DB_MAX_ROWS = 1000`, `PGRST_OPENAPI_MODE = disabled`,
`PGRST_LOG_LEVEL = error`.

Errores: `portal_negocio()` lanza `RAISE EXCEPTION 'sesión sin negocio' USING
ERRCODE='42501'`, que PostgREST traduce a **403**. Las funciones de escritura
devuelven `{ok:false, error:'…'}` en vez de excepción cuando el fallo es de
negocio.

---

## 3. El frontend del portal

`[CONFIRMADO]` `portal/publico/index.html`, 47 KB, sin build ni framework:
`const API = '/api'` y una función `rpc(fn, args)` que hace
`fetch('/api/rpc/'+fn, {method:'POST', headers:{Authorization:'Bearer '+jwt}})`.
El JWT se obtiene del fragmento `#t=<token>` al cargar.

Pantallas observadas por sus ids y llamadas: perfil/negocio, productos y
conteos, alias pendientes, movimientos y documentos, cartera y pagos,
conocimiento y pendientes, snapshots (histórico), recomendaciones, pedido,
informes, cotizaciones y cotizador.

`portal/publico/cotizacion.html` (5 KB) es la vista pública de una cotización.

`[CONTRADICCIÓN]` `AGENTS.md` lista **«cotizador»** entre lo **congelado**. Está
implementado de punta a punta: tabla `cotizaciones`, 4 funciones
`portal_cotizacion_*`, pantalla en el portal y una página pública propia.
«Congelado» debe leerse como «no se invierte más», no como «no existe»; pero un
lector nuevo lo entendería al revés.

---

## 4. Lo que NO existe `[CONFIRMADO]`

- No hay API pública para terceros.
- No hay endpoint de ingesta por HTTP: los archivos entran sólo por el chat.
- No hay webhook de salida hacia sistemas del cliente.
- No hay webhook de pago (Wompi está congelado); `router_plan` sólo pinta un
  enlace si existe `parametros.pago_enlace` para ese negocio, y **no hay
  ninguna fila con esa clave**.
- No hay OpenAPI ni documentación autogenerada (deshabilitada a propósito).
- No hay rate limiting propio: el único freno es
  `N8N_CONCURRENCY_PRODUCTION_LIMIT = 5`.
