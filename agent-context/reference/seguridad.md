# Seguridad y aislamiento

Auditado el 2026-08-19 contra `pg_roles`, `information_schema.role_table_grants`,
`has_function_privilege`, `docker-compose.yml`, `portal/Caddyfile` y los
generadores de workflows.

---

## 1. Autenticación

| Superficie | Mecanismo | Fuerza |
|---|---|---|
| Telegram (entrada) | secreto compartido en cabecera `X-Telegram-Bot-Api-Secret-Token`, comparado en el nodo `Normalizar` | correcto para el caso; el secreto queda **embebido en el JSON del workflow** |
| WhatsApp (entrada) | **ninguno criptográfico**: ruta secreta + filtro por `phone_number_id` | débil y declarado como tal |
| Portal (apertura) | token de 24 bytes aleatorios (`gen_random_bytes`), un solo uso, 15 min, guardado como `sha256` | correcto |
| Portal (sesión) | JWT HS256 firmado en SQL (`jwt_firmar`) con el secreto que PostgREST inyecta como GUC; 12 h | correcto; el secreto no vive en la base |
| Cotización pública | token en `cotizaciones.token` (`UNIQUE`), sin expiración obligatoria | `vigente_hasta` es opcional |
| n8n (editor) | cuenta de propietario de n8n | **sólo en `127.0.0.1:5678`**, nunca en internet |
| Postgres | contraseña por rol | **sólo en `127.0.0.1:5432`** |

`[CONFIRMADO]` No hay contraseñas de usuario final en ninguna parte. La
identidad es la del canal de mensajería.

`[CONFIRMADO]` `portal_sesion_abrir` devuelve **un solo mensaje de error**
(`enlace_invalido`) para «no existe», «ya se usó» y «venció». Comentario
explícito: no hay nada que ganar contándole al que prueba tokens cuál de las
tres fue.

`[CONFIRMADO]` `portal_token_crear` **invalida** los tokens anteriores del mismo
usuario al emitir uno nuevo.

---

## 2. Autorización

`[CONFIRMADO]` Dos sistemas independientes.

### En el chat

| Nivel | Comprobación |
|---|---|
| Consentimiento de datos | `usuarios.autorizacion_datos`; hasta que sea true, todo lo que no sea informativo o de menú devuelve `sistema.consentimiento` |
| Rol admin | `router_h_admin` exige `p_ctx->>'rol' = 'admin'`; si no, devuelve `sistema.no_entendido` (no «no autorizado») |

`[CONFIRMADO]` `PLANES-001` cumplido: el menú (`mod:`, `modayuda:`) va **antes**
del consentimiento a propósito; el permiso se pide al elegir una opción que
entrega datos. El texto `sistema.consentimiento` (1785 caracteres) declara que
el análisis lo hace una IA que puede equivocarse, y el pie de cada informe lo
repite.

`[CONFIRMADO]` Los tres roles del enum sólo tienen un efecto real: `admin`.
`dueno` y `operador` son indistinguibles para el código de producción.

### En el portal

`[CONFIRMADO]`, verificado contra el catálogo:

```
Roles:      authenticator (LOGIN), portal_anon (NOLOGIN), portal_usuario (NOLOGIN)
Membresía:  authenticator es miembro de portal_anon y de portal_usuario
GRANTs sobre tablas para portal_anon / portal_usuario / authenticator:
            NINGUNO  (consulta a role_table_grants: 0 filas)
EXECUTE:    portal_anon    -> portal_sesion_abrir, portal_cotizacion_publica
                              (+ funciones de extensiones: pgcrypto, pg_trgm, unaccent)
            portal_usuario -> las 27 portal_* de negocio
```

`[CONFIRMADO]` `PORTAL-001` se cumple en sus cuatro invariantes:

1. El rol de PostgREST no tiene permiso sobre ninguna tabla. ✔
2. Lo único ejecutable desde HTTP son las funciones `portal_*`, con GRANT
   explícito una por una. ✔
3. El `negocio_id` sale siempre del JWT: **ninguna** función `portal_*` acepta
   `negocio_id` como parámetro. ✔
4. Las migraciones que crean o cambian una RPC terminan en `NOTIFY pgrst`
   (verificable en `agent-context/history/migraciones/033_portal.sql` y siguientes).

---

## 3. Aislamiento por empresa

`[CONFIRMADO]` **No hay RLS** (congelado en `AGENTS.md`). El aislamiento es por
construcción:

| Camino | Cómo aísla |
|---|---|
| Chat | `router_ctx` resuelve `negocio_id` desde `usuarios` vía `usuario_de_canal`. Todos los handlers reciben ese id en el contexto |
| Portal | `portal_negocio()` = `portal_claim('negocio_id')` del JWT; lanza `42501` si falta. Todas las funciones lo usan en su `WHERE` |
| Análisis | `hallazgos_*` y `recomendaciones_negocio` reciben `p_negocio_id` y filtran por él |

`[INFERIDO]` **Riesgo estructural**: el aislamiento depende de que **cada
función** recuerde poner el filtro. Un `WHERE negocio_id` olvidado en una
función `SECURITY DEFINER` filtra datos entre empresas sin que nada lo detecte.
No hay una barrera que lo impida por defecto, ni un test que lo compruebe.

`[CONFIRMADO]` Un caso donde el aislamiento **no aplica por diseño**:
`formatos_documento` es global. Un layout aprendido de los archivos del negocio
A queda disponible para el negocio B. Sólo son nombres de columna y parámetros
de parseo —no cifras—, pero es información derivada de un cliente compartida
entre todos.

`[CONFIRMADO]` `admin_reporte` **cruza todos los negocios** a propósito:
`/salud`, `/matching`, `/pendientes` y `/consumo` reportan la base entera. Es un
comando de operador de la instalación, no del dueño de una pyme; está protegido
por `rol='admin'`.

---

## 4. Secretos

| Secreto | Dónde vive | Riesgo |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | `.env`, sólo lo ve el contenedor `registrador` | el contenedor de n8n **no** lo tiene; por eso el envío usa el nodo de Telegram y no HTTP directo |
| `TELEGRAM_WEBHOOK_SECRET` | `.env` → **embebido en `workflows/wf_router.json`** | el JSON está en git |
| `WA_VERIFY_TOKEN`, `WA_PHONE_NUMBER_ID` | `.env` → **embebidos en `workflows/wf_wa_router.json` y `wf_enviar.json`** | idem |
| API key del LLM | credencial `chasquiDs0000000001` en la base de n8n, cifrada con `N8N_ENCRYPTION_KEY` | correcto; no está en el repo |
| `PORTAL_JWT_SECRET` | `.env` → `PGRST_JWT_SECRET` y `PGRST_APP_SETTINGS_JWT_SECRET` | **no se guarda en la base**; SQL lo lee por GUC |
| Contraseñas de Postgres | `.env` | `.env` está en `.gitignore` |
| `N8N_ENCRYPTION_KEY` | `.env` | si cambia, todas las credenciales de n8n dejan de descifrarse |

`[CONFIRMADO]` `.gitignore` excluye `.env`. **Pero** el secreto del webhook de
Telegram y el verify token de WhatsApp **sí** viajan en los JSON versionados,
por diseño del generador. `[INFERIDO]` Cualquiera con acceso al repositorio
puede inyectar updates falsos de Telegram si además conoce la URL del túnel.

---

## 5. Acceso a la base

`[CONFIRMADO]`

| Rol | Uso | Superusuario |
|---|---|---|
| `postgres` | migraciones, respaldos, `bin/preparar-portal.sh` | **sí** |
| `chasqui` | dueño del esquema; lo usan n8n y todos los scripts | no |
| `n8n` | sólo la base `n8n` | no |
| `authenticator` | PostgREST; sin permisos propios | no |
| `portal_anon`, `portal_usuario` | destino de `SET ROLE`; sin acceso a tablas | no (NOLOGIN) |

`[CONFIRMADO]` `bin/preparar-portal.sh` existe como script aparte y no como
migración porque `CREATE ROLE` no está al alcance del dueño de la base.

`[INFERIDO]` **n8n corre con el rol `chasqui`**, dueño del esquema. Un nodo
Postgres puede ejecutar cualquier SQL sobre cualquier tabla de cualquier
negocio. La separación de privilegios existe para el portal, no para n8n. Es
coherente con el diseño (n8n es parte del sistema, no un cliente), pero implica
que comprometer el editor de n8n es comprometer la base entera — de ahí que el
editor **no** esté expuesto.

---

## 6. Acceso a archivos

`[CONFIRMADO]` Los archivos del usuario viven **dentro de Postgres**
(`documentos.contenido bytea`), no en disco. No hay servidor de ficheros, no hay
S3, no hay ruta de descarga. `portal_documentos` devuelve metadatos (nombre,
mime, tamaño, estado), **no** el contenido.

`[CONFIRMADO]` Los binarios transitorios de n8n van al volumen `n8n_data`
(`N8N_DEFAULT_BINARY_DATA_MODE=filesystem`), y n8n los poda con sus ejecuciones.

---

## 7. Exposición

`[CONFIRMADO]` Superficie pública total: **tres rutas** por un hostname.

- `/webhook/*` — n8n. Sin autenticación en el proxy; la valida el workflow.
- `/api/*` — PostgREST. Sin JWT, el rol es `portal_anon`, que sólo puede
  ejecutar dos funciones.
- `/portal/*` — HTML estático, sin secretos (el token llega en el fragmento
  `#t=`, que **no** se envía al servidor).

Todo lo demás: `404` seco.

`[CONFIRMADO]` `PGRST_OPENAPI_MODE=disabled`: PostgREST no publica su esquema,
así que enumerar las funciones desde fuera exige adivinar nombres.

---

## 8. Lo que NO está implementado

`[CONFIRMADO]`

- **RLS**: no existe (congelado).
- **Verificación de firma de WhatsApp**: no existe.
- **Rate limiting**: no existe. El único freno es la concurrencia de n8n (5).
- **Auditoría de acceso**: no existe. No hay log de quién leyó qué. `fallas`
  registra errores, no accesos.
- **Rotación de secretos**: no hay mecanismo; cambiar el secreto del webhook
  exige regenerar e importar el workflow.
- **Cifrado en reposo**: no hay. Los archivos originales y los datos de negocio
  están en claro en Postgres.
- **Expiración del JWT del portal más allá de 12 h**: no hay refresh ni
  revocación. Un JWT emitido sigue siendo válido 12 h aunque se revoque el
  token que lo originó.
- **Borrado de datos a petición del usuario**: no hay ruta de producto. Sólo
  `bin/limpiar_negocio.sh`, que es una herramienta de operación.

---

## 9. Riesgo operativo observado hoy

`[CONFIRMADO]` El bot recibe `Forbidden` de Telegram desde las 13:41 del
2026-08-19, 51 veces. Causa candidata registrada en
`agent-context/history/auditorias/2026-08-19/orden-de-trabajo.md` A-12: el usuario bloqueó el bot. `[INFERIDO]` Si
así fue, la causa raíz es la ráfaga de alertas (A-10): 57 intentos de aviso en
una tarde, todos de la misma regla, sobre un cálculo que además está mal (A-11).
