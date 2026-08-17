# Guía técnica — Chasqui n8n

Documento de referencia para quien opera, mantiene o extiende el sistema.

---

## 1. Tesis de diseño

n8n es un **runtime fijo de 7 workflows** que casi nunca se tocan. Todo el
comportamiento del sistema —los pasos de la conversación, los textos, los
umbrales, los prompts del LLM, los formatos de archivo que se aceptan, las
reglas que disparan una recomendación, las preguntas que sabe responder, cuándo
avisa y cuándo se calla— **vive en filas de Postgres**, no en nodos de n8n.

La regla operativa que lo verifica: **si para lanzar un servicio nuevo hay que
abrir el editor de n8n, el diseño se rompió.** Agregar un servicio es un
conjunto de `INSERT`, no un cambio de workflow.

Corolario de reparto de responsabilidades:

- **Postgres hace** todo lo determinístico: parseo, normalización, matching,
  cálculo, máquina de estados de la conversación, decisiones.
- **n8n hace** solo lo que Postgres no puede: llamadas HTTP (LLM), descarga de
  archivos, reintentos con backoff. Nada de aritmética ni
  reglas de negocio en los nodos.

Motivo técnico, no estético: dentro de una transacción de Postgres una llamada
HTTP no tiene timeout controlable ni reintento, y un cliente lento mantendría
tomado el lock de la sesión bloqueando al usuario.

---

## 2. Stack y topología

```
Telegram / WhatsApp ──webhook──►  cloudflared (túnel)  ──►  proxy (Caddy)
Navegador (portal)  ──────────────────────────────────►      │
                                          ┌──────────────────┼──────────────┐
                                          ▼                  ▼              │
                                   n8n :5678          PostgREST :3000       │
                                          │                  │      (/portal: estáticos)
                            ┌─────────────┴────┐             │
                            ▼                  ▼             ▼
                     Proveedor LLM        Postgres :5432 ◄────┘
                     (redacción)          ├── base "chasqui" (negocio: todo)
                                          └── base "n8n"     (runtime n8n)
```

| Servicio | Imagen | Rol |
|---|---|---|
| `postgres` | postgres:16 | Dos bases separadas en una instancia: `chasqui` (negocio) y `n8n` (runtime). |
| `n8n` | n8nio/n8n:2.31.5 | Orquestador. Backend en la base `n8n` (no SQLite). |
| `postgrest` | postgrest:v12.2.12 | API del portal. Solo RPC `portal_*`; sin puertos publicados, se llega por el proxy. |
| `proxy` | caddy:2-alpine | Un solo hostname público para tres cosas: `/webhook` (n8n), `/api` (PostgREST) y `/portal` (los estáticos de `portal/publico`). El editor de n8n **no** queda expuesto. |
| `cloudflared` | cloudflare/cloudflared | Quick tunnel, apuntando al proxy. Perfil `local`. |
| `registrador` | alpine:3.20 | Descubre la URL del túnel y re-registra el webhook de Telegram (y la suscripción de Meta). Perfil `local`. |

**Migración a la nube:** apagar el perfil `local` (cloudflared + registrador) y
fijar `WEBHOOK_URL` al dominio real (más el parámetro `portal_url_base`, que es
una fila de la base y no una variable). Ningún
componente se reescribe. Los archivos van en `bytea`, así que no hay bucket que
migrar; un `pg_dump` cubre todo.

### 2.1 Variables de entorno clave (`.env`)

| Variable | Sentido |
|---|---|
| `N8N_ENCRYPTION_KEY` | Cifra las credenciales de n8n. **Fijada antes del primer arranque.** Si cambia, todas las credenciales dejan de descifrarse. |
| `WEBHOOK_URL` | URL pública. Vacía en local (la descubre el registrador); fija en nube. |
| `TELEGRAM_WEBHOOK_SECRET` | Secreto que Telegram devuelve en la cabecera `X-Telegram-Bot-Api-Secret-Token`. wf_router lo verifica. |
| `TELEGRAM_WEBHOOK_PATH` | Ruta fija del webhook en n8n (`telegram`). |
| `CHASQUI_DB_*` / `N8N_DB_*` | Credenciales de cada base. Usuarios distintos. |
| `DEEPSEEK_API_KEY` | Autenticación del LLM. |
| `DEEPSEEK_BASE_URL` | Endpoint del proveedor LLM. Ya no está hardcodeado: entra por `LLM_URL` en `bin/wf_lib.py` y se hornea en el JSON al generar los workflows. |
| `PORTAL_DB_PASSWORD` | Contraseña del rol `authenticator` con el que se conecta PostgREST. La pone `bin/preparar-portal.sh`. |
| `PORTAL_JWT_SECRET` | Secreto con el que `portal_sesion_abrir` firma el JWT **y** con el que PostgREST lo verifica. No se guarda en la base: viaja como `app.settings.jwt_secret`. |
| `PROXY_PORT` | Puerto local del proxy (`127.0.0.1:8080` por defecto). La base pública del portal **no** es una variable de entorno: es el parámetro `portal_url_base` de la base, que es quien arma el enlace de `/portal`. |
| `WA_*` | Bloque de WhatsApp Cloud API (`WA_PHONE_NUMBER_ID`, `WA_ACCESS_TOKEN`, `WA_VERIFY_TOKEN`, `WA_WEBHOOK_PATH`…). Ver `docs/WHATSAPP.md`. |

n8n está configurado con `EXECUTIONS_DATA_SAVE_ON_SUCCESS=none`,
`SAVE_ON_ERROR=all`, `PRUNE=true`, `MAX_AGE=168` (7 días): solo guarda los
fallos, que son los que se miran. `N8N_DEFAULT_BINARY_DATA_MODE=filesystem`
(el modo en memoria fue removido en 2.0). `EXECUTIONS_TIMEOUT=300`.

---

## 3. Modelo de datos (base `chasqui`)

### 3.1 Tipos enumerados

| Enum | Valores |
|---|---|
| `rol_usuario` | `dueno`, `operador`, `admin` |
| `estado_sesion` | `intake`, `recibiendo`, `procesando`, `completada`, `fallida`, `expirada` |
| `estado_doc` | `pendiente`, `parseado`, `error` |
| `estado_ejec` | `preparando`, `procesando`, `validando`, `completada`, `fallida`, `bloqueada` |
| `tipo_movimiento` | `compra`, `venta`, `ajuste` |
| `origen_alias` | `exacto`, `trigram`, `manual`, `pendiente` |

### 3.2 Tablas núcleo

**`negocios`** — la unidad de facturación y de umbrales.
`id, nombre, nit, tipo, plan, cupo_tokens_mes (0=bloqueado), creado_en`

**`usuarios`** — identidad = `telegram_user_id` (UNIQUE). No hay login.
`id, negocio_id, telegram_user_id, telegram_chat_id, telegram_username, nombre,
rol, autorizacion_datos, autorizacion_fecha, creado_en`

**`servicios`** — catálogo declarativo.
`codigo (PK), nombre, descripcion, entrada, funcion_hallazgos,
modulo_codigo, orden, activo`
*(`pasos jsonb` — el guion de intake de la 001 — se dio de baja en la `057`:
letra muerta desde la 012, cuando el router pasó a resolver los pasos solo.)*
`entrada` distingue los que piden archivos de los que se disparan escribiendo.
`modulo_codigo` dice bajo qué botón del menú aparece (NULL = no se ofrece).

**`modulos`** — el primer nivel del menú del chat (migración 045).
`codigo (PK), nombre, titular, ayuda, orden, activo`
Un módulo = un botón en la bienvenida (hoy uno solo, "¿Qué puedo hacer?"); sus servicios activos son los botones del
segundo nivel. `titular` y `ayuda` son el cuerpo HTML de los dos mensajes del
módulo: viven acá y no en `plantillas` porque son **por módulo**, así agregar un
módulo sigue siendo un INSERT. Los arma `teclado_modulos()` / `teclado_modulo()`.

**`sesiones`** — máquina de estados de la conversación.
`id, usuario_id, negocio_id, servicio_codigo, paso, estado, contexto jsonb,
ultima_actividad, creada_en, cerrada_en`
Índices parciales sobre sesiones abiertas (`cerrada_en IS NULL`).

**`documentos`** — el archivo original vive aquí, en `bytea`.
`id, sesion_id, negocio_id, formato_codigo, nombre_archivo, mime, hash bytea,
contenido bytea, tamano, estado, error, creado_en`
`UNIQUE(negocio_id, hash)` → subir el mismo archivo dos veces no lo duplica;
un retry de n8n sobre el registro es idempotente.

**`productos`** — catálogo canónico por negocio.
`id, negocio_id, nombre_canonico, codigo_barras, unidad, categoria, creado_en`
`UNIQUE(negocio_id, codigo_barras)` parcial. Índice GIN trigram sobre el nombre.

**`alias`** — texto libre observado → producto.
`id, negocio_id, texto_norm, producto_id (NULL=pendiente), confianza, origen, creado_en`
`UNIQUE(negocio_id, texto_norm)`. Índice GIN trigram + índice parcial de pendientes.

**`movimientos`** — compras/ventas normalizadas (grano de línea).
`id, negocio_id, documento_id, tipo, fecha, producto_id, alias_id, cantidad,
valor_unitario, valor_total, impuesto, raw jsonb, creado_en`
**Guarda todo lo que el negocio cargó, sin importar su plan** (053). El plan
limita lo que se lee, no lo que se almacena: para eso está `mov_visibles`.

**`conteos_inventario`** (054) — stock declarado por el negocio en una fecha.
`id, negocio_id, producto_id, fecha, unidades, origen (portal|archivo|chat),
documento_id, nota, creado_en` · `UNIQUE(negocio_id, producto_id, fecha)`
Se acumulan: siempre gana el conteo más reciente. Sin conteos, el stock se
sigue estimando como compradas − vendidas, y queda marcado como tal.

**`ejecuciones`** — una corrida de servicio.
`id, sesion_id, negocio_id, servicio_codigo, estado, prompt_id, hallazgos jsonb,
texto, pdf bytea, tokens_prompt, tokens_salida, costo, error, inicio, fin`
Índice parcial `idx_ejec_colgadas` sobre estados no terminales → lo usa el reaper.

**`snapshots_negocio`** (058) — la memoria del negocio.
`id, negocio_id, fecha, version, periodo daterange, salud jsonb, metricas jsonb,
origen (ejecucion|backfill|manual), ejecucion_id, creado_en`
`UNIQUE(negocio_id, fecha)`: dos análisis el mismo día no son dos estados del
negocio, el segundo corrige al primero.
Es **estado empresarial, no una copia del informe**: márgenes por producto,
coberturas, gasto por proveedor, precio por producto y proveedor, unidades
vendidas, notas de salud, totales del periodo y **con qué umbrales se midió**.
Nada de texto narrado ni HTML — así dos snapshots siguen siendo comparables
aunque el informe cambie de diseño por completo. Ver §5.4.

**`recomendaciones`** (059) — lo que Chasqui le dijo al dueño y qué pasó (R-III).
`id, negocio_id, regla, clave_objeto, titulo, problema, impacto, impacto_mes,
impacto_tipo, prioridad, opciones, origen_stock, estado, cerrada_por, resultado,
detectada_en, vista_en, revisada_en, cerrada_en, veces_vista, ejecucion_id`
La identidad es `(negocio_id, regla, clave_objeto)` — `producto:<id>` o
`proveedor:<nombre>`— y la garantiza un **índice único parcial sobre las
abiertas**: un problema que vuelve tras cerrarse abre una fila nueva en vez de
pisar la vieja, porque "te lo dije, lo arreglaste y volvió" es historia que hay
que poder contar. Ver §5.5.

**`metricas_resultado`** (066) — qué magnitud mira cada regla y hacia dónde
debería moverse. `regla (PK), metrica` (lista cerrada por CHECK: `costo`,
`margen_pct`, `dias_cobertura`, `balance`, `concentracion_pct`,
`unidades_vendidas`, `ventas`), `direccion (sube_mejor|baja_mejor),
umbral_pct` (5 por defecto: cambio mínimo para dejar de ser `neutro`). Es una
**tabla, no un algoritmo**: medir el resultado de una regla nueva es un INSERT.
Ver §5.7.

**`alertas_enviadas`** (067) — el cooldown de la proactividad.
`id, negocio_id, regla, clave_objeto, enviada_en`. Sin esta tabla el mismo
problema se avisaría en cada corrida del cron.

**`intenciones`** (063) — qué preguntas sabe responder Chasqui.
`codigo (PK), nombre, patrones text[], metrica, periodo, filtros text[],
comparativo, orden, activo`. Es un **contrato de datos, no un despachador**: la
fila declara qué se pide y sobre qué ventana, y un único agregador genérico lo
calcula. Una pregunta nueva es un INSERT. Ver §5.6.

**`terceros` / `facturas` / `pagos`** (`036`; alta manual en la `069`) — clientes
y proveedores por nombre normalizado, sus facturas y sus abonos. `facturas` se
llena desde el XML de la DIAN y, desde F2, también a mano por el portal
(`portal_factura_guardar`). El tercero se reusa por nombre normalizado: sin eso
"Panadería El Sol" y "panaderia el sol" serían dos deudores y cada cartera se
vería la mitad de grande. Ver §5.8.

**`conocimiento` / `conocimiento_pendiente`** — la KB del negocio: precios,
hechos y FAQs que el dueño enseñó (`/saber`, el portal, o "aplicar el precio
sugerido" de D1), y las preguntas que no se supieron responder.

**`portal_tokens`** (033) — enlaces de un solo uso del portal.
`id, usuario_id, token_hash, expira_en, usado_en`. Ver §5.10.

**`identidades`** (044) — `(canal, externo_id) → usuario`. Es lo que permite que
WhatsApp y Telegram sean el mismo usuario sin duplicar la máquina de estados.

**`cotizaciones`** — cotizaciones armadas desde el portal, compartibles por
enlace público (`portal_cotizacion_publica`).

**`fallas`** — lo que registra wf_error.
`id, workflow, ejecucion_id, sesion_id, tipo, transitoria, intentos, detalle jsonb, creada_en`

### 3.3 Tablas de contenido (sacan los textos de los nodos)

**`plantillas`** — textos de mensajes **y sus botones**. `clave (PK), canal,
cuerpo, formato, variables jsonb, teclado jsonb, crudas jsonb, version, activo`.
`respuestas[]` devuelve `{plantilla, vars, teclado?}`; el texto final y el
`reply_markup` se resuelven en Postgres con `resolver_plantilla`.

- **`teclado`** — el teclado inline en forma abstracta, no la de Telegram:
  `[[{"texto":"🚀 Empezar","dato":"/nueva"}], [{"texto":"❓ Cómo funciona","dato":"/comofunciona"}]]`.
  Filas → botones; `dato` viaja como `callback_data`. Admite `{{variables}}` en
  ambos campos. `teclado_markup` lo traduce a `{"inline_keyboard": [...]}`.
  Agregar un botón a un paso de la conversación es un `UPDATE`.
- **`crudas`** — nombres de variables que se insertan **sin escapar** porque su
  valor ya es HTML nuestro (hoy: el informe renderizado). Todo lo demás se
  escapa siempre. Es la frontera de confianza de la migración 022, hecha
  explícita y consultable: `SELECT clave, crudas FROM plantillas WHERE crudas <> '[]'`.

Las piezas de layout del informe (`informe.encabezado`, `informe.seccion`,
`informe.punto`, `informe.acciones`, `informe.accion`, `informe.pie`) también son
filas de esta tabla: cambiar cómo se ve un informe es un `UPDATE`, no editar un
nodo. Las compone `informe_render`.

**`prompts`** — prompt del LLM por servicio. `id, servicio_codigo, version,
sistema, usuario, modelo, temperatura, max_tokens, activo`. Índice único parcial:
un solo prompt activo por servicio. Iterar el tono = INSERT de otra versión + apagar la anterior.

**`tipos_negocio`** — la naturaleza del negocio, como botones. `codigo (PK),
nombre, orden, activo`. Se pregunta una sola vez, antes del primer análisis, y
queda en `negocios.tipo`; de ahí viaja a los hallazgos como `tipo_negocio`. Un
18% de margen es normal en una distribuidora y flojo en un minimercado: sin ese
dato el informe compara contra un promedio que no existe.

**`parametros`** — umbrales. `(negocio_id NULL=global, clave, valor jsonb)`.
La fila del negocio pisa la global. Se lee con `parametro(negocio_id, clave)`.

### 3.4 Tablas de ingesta extensible

**`formatos_documento`** — `codigo (PK), nombre, mime_patrones text[],
extensiones text[], funcion_parseo text, deteccion jsonb, mapeo jsonb, activo,
clase, huella, origen`.
`funcion_parseo` es el nombre de la función que parsea ese formato; el despacho
la ejecuta dinámicamente. `mapeo` traduce columnas del proveedor a campos
canónicos (para tabulares).

`clase` decide el camino: `'documento'` lo parsea Postgres desde el `bytea`
(DIAN XML), `'tabular'` necesita que n8n extraiga las filas primero.

`huella` identifica un layout de POS por sus cabeceras (md5 de los nombres
normalizados y ordenados), no por el nombre del archivo. Es la clave de que la
ingesta no dependa de un esquema fijo: si la huella es nueva, el LLM infiere el
`mapeo`, se valida y se persiste como fila nueva con `origen='inferido'`. El
segundo archivo del mismo POS ya no gasta tokens.

El `mapeo` de un tabular declara lo que hace falta para normalizar, y la carga
**sí lo lee** (antes declaraba `decimal` y no lo usaba):

```json
{"tipo":"venta", "decimal":",", "miles":".", "formato_fecha":"DD/MM/YYYY",
 "delimitador":",", "max_pct_nulos":20,
 "columnas":{"fecha":"Fecha Venta","producto":"Descripcion","cantidad":"Unidades",
             "valor_unitario":"Vr Unitario","valor_total":"Vr Total",
             "categoria":"Linea","codigo":"Codigo","unidad":"…"}}
```

**`prompts_tecnicos`** — `(clave PK, sistema, usuario, modelo, temperatura,
max_tokens, activo)`. Prompts que no pertenecen a un servicio, así que no caben
en `prompts` (tiene FK a `servicios`). Hoy: `ingesta.inferir_mapeo`.

**`parametros.ingesta_extractores`** — mapa extensión → operación del nodo
Extract From File (`{"csv":"csv","xls":"xls","xlsx":"xlsx","ods":"ods",…}`).
Estar en ese mapa **es** la definición de "esto es una tabla": agregar un tipo
de archivo tabular es editar esa fila, no tocar un condicional.

**`servicios_entradas`** — qué formatos pide cada servicio.
`(servicio_codigo, formato_codigo, obligatorio, min_archivos, max_archivos)`

---

## 4. Superficie de funciones

n8n **nunca escribe un INSERT directo**; solo llama funciones.

### 4.1 Utilidades

| Función | Firma → retorno | Qué hace |
|---|---|---|
| `norm_texto` | `(text) → text` IMMUTABLE | minúsculas, sin acentos (`unaccent`), sin dobles espacios. Indexable. |
| `parametro` | `(negocio_id, clave) → jsonb` | umbral del negocio o, si no hay, el global. |
| `esc_html` | `(text) → text` IMMUTABLE | escapa `& < >` para el modo HTML de Telegram. |
| `resolver_plantilla` | `(clave, vars jsonb, teclado jsonb) → jsonb` | devuelve `{texto, formato, teclado}`. Sustituye `{{var}}` escapando el valor salvo que la variable esté en `crudas`; degrada devolviendo la clave (escapada) si la plantilla no existe. El `teclado` del parámetro pisa el de la fila solo si es un array (así `'null'::jsonb` no borra el de la fila). |
| `teclado_markup` | `(teclado jsonb, vars jsonb) → jsonb` | traduce el teclado abstracto a `reply_markup`. Aplana a **un botón por fila**, descarta botones sin `dato` o con `url`, recorta el `callback_data` a 64 caracteres y aplica el tope de `parametros.teclado_max_filas` (ver §6.4 por qué). Nunca devuelve NULL: sin botones da `{"inline_keyboard": []}`. |
| `teclado_intake` | `() → jsonb` | El teclado de "¿qué querés hacer?". Con un solo módulo activo entra directo a sus servicios; con varios muestra los módulos. Reemplaza (`057`) a `teclado_servicios`, que era un segundo menú con textos propios para los mismos servicios. |
| `usuario_de_telegram` | `(evento jsonb) → bigint` | localiza o crea el usuario por `telegram_user_id`. |
| `cifra_norm` / `cifra_variantes` | `(text) → text` / `text[]` IMMUTABLE | forma canónica de un número y sus lecturas posibles (`1.234` = mil doscientos treinta y cuatro **o** uno con 234 milésimas). Las usa `validar_cifras`. |
| `fmt_decimal` | `(numeric) → text` IMMUTABLE | decimal con coma y sin ceros de relleno (`28.40` → `28,4`). |
| `mes_es` / `periodo_es` | `(date)` / `(date, date) → text` | nombre del mes y rango legible (`del 1 al 24 de julio de 2026`). |
| `limpiar_marcado` | `(text) → text` IMMUTABLE | quita `**`, `__` y `#` de encabezado que se le escapen al modelo. Deja los asteriscos y guiones bajos sueltos quietos, para no mutilar `ACEITE_1L`. |
| `informe_render` | `(estructura jsonb, hallazgos jsonb, servicio) → text` | arma el informe en HTML de Telegram a partir del JSON del modelo y las piezas de `plantillas`. Devuelve NULL si la estructura no sirve. Ver §6.3. |

### 4.2 Ingesta

| Función | Qué hace |
|---|---|
| `ingesta_registrar_documento(sesion_id, negocio_id, nombre, mime, contenido bytea) → jsonb` | Hash sha256, INSERT idempotente y **detección en dos fases**: por mime/extensión decide la *clase*. Si es `'documento'` devuelve el formato ya asignado; si es tabular deja `formato_codigo` NULL y devuelve `{requiere_tabla:true, operacion}` porque el formato exacto depende de las cabeceras. Si no es ninguna de las dos, marca error con el tipo de archivo por nombre. |
| `ingesta_identificar_tabular(documento_id, columnas text[]) → jsonb` | Calcula la huella de las cabeceras y busca el formato. Si existe, lo asigna al documento y devuelve `{requiere_inferencia:false}` — cero tokens. Si no, devuelve `{requiere_inferencia:true, columnas}` para que wf_ingesta le pida el mapeo al LLM. |
| `ingesta_registrar_formato_inferido(documento_id, columnas text[], mapeo jsonb) → jsonb` | **Valida antes de persistir**: solo claves canónicas, solo columnas que existan de verdad en el archivo, y `fecha` + (`valor_total` o `valor_unitario`) obligatorias. Si pasa, crea la fila `tabular_<huella>` con `origen='inferido'`. Un mapeo malo guardado envenenaría todos los archivos futuros de ese POS, así que acá se rechaza con motivo. |
| `ingesta_procesar_documento(documento_id) → jsonb` | **Despacho por `clase`**, no por aritmética de `pg_proc.pronargs` (que era adivinar). Los tabulares devuelven `{requiere_filas:true}`; los documentos ejecutan su `funcion_parseo` con `EXECUTE`. Captura errores → marca solo ese documento. |
| `ingesta_parsear_dian(documento_id) → jsonb` | Parser UBL 2.1 (ver §5). |
| `ingesta_cargar_tabular(documento_id, filas jsonb) → jsonb` | Normaliza con el `mapeo`, **mide, y solo entonces inserta**. Si más del `max_pct_nulos` de las filas quedó sin fecha o sin valor, el documento va a `error` con un motivo que nombra la columna y el formato, y no se inserta **ni una** fila. Respeta un error previo de la cadena en vez de pisarlo. Pega en `raw` las claves canónicas (`producto`, `codigo`, `unidad`, `categoria`) que `match_resolver_documento` busca. |
| `ingesta_num(valor jsonb, decimal, miles) → numeric` | `"$ 1.234.567,89"` → `1234567.89`; `"(1.234,50)"` → `-1234.50`. Recibe **jsonb** a propósito: un número real (lo que da n8n al leer un xlsx) se usa tal cual, porque aplicarle reglas de separadores lo destruye — `replace('.','')` sobre `2500.5` daría `25005`. Valor ilegible → NULL, y la compuerta lo cuenta. |
| `ingesta_fecha(valor jsonb, formato) → date` | `to_date` con el formato declarado. Sin formato solo acepta ISO: `dd/mm` y `mm/dd` son indistinguibles y adivinar era el bug (el contenedor corre con `DateStyle = ISO, MDY`, así que `'12/03/2026'::date` daba **3 de diciembre**). También convierte el serial de Excel (`46000` → fecha), época `1899-12-30`. |
| `ingesta_huella(columnas text[]) → text` | md5 de las cabeceras normalizadas y ordenadas: estable ante orden, acentos, mayúsculas y espacios dobles. |
| `ingesta_resumen_documento(documento_id) → jsonb` | Lo que la base entendió: filas, rango de fechas, total, productos distintos, sin resolver. Sale de `movimientos`, no del LLM: es lo que quedó guardado. |
| `ingesta_marcar_error(documento_id, error) → jsonb` | Marca `estado='error'` sin tumbar la sesión. |

### 4.3 Matching

| Función | Qué hace |
|---|---|
| `match_resolver_producto(negocio_id, texto) → jsonb` | (1) alias exacto; (2) trigram sobre productos ≥ umbral → auto-confirma y memoriza alias; (3) si no, alias `pendiente`. Umbral: `parametro('match_umbral_trgm')`, default 0.45. |
| `match_resolver_documento(documento_id) → jsonb` | Recorre los movimientos del documento. Compras con código de barras **siembran** el catálogo (producto por código); sin código, resuelven por texto. Devuelve `{total, resueltos, pendientes, productos_nuevos}`. |
| `match_confirmar_alias(alias_id, producto_id) → void` | Confirmación manual; reaplica a los movimientos huérfanos que coincidan. Desde la `057` tiene llamadores: `portal_alias_confirmar`. |
| `alias_pendientes(negocio_id, limite) → jsonb` | Los alias sin resolver, cada uno con **cuántos movimientos y cuánta plata** representa y el mejor candidato del trigram. Solo lee. |

### 4.4 Cálculo y ejecución

| Función | Qué hace |
|---|---|
| `hallazgos_generar(negocio_id) → jsonb` | **Solo lee vistas**, aplica umbrales de `parametros` y arma el JSON que verá el LLM: `resumen, margen_bajo, deriva_costo, baja_cobertura, pareto`, más `salud`, `recomendaciones` y `tipo_negocio`. Nada de aritmética suelta. |
| `recomendaciones_negocio(negocio_id) → jsonb` | **El motor de reglas** (§5.1). Devuelve los problemas del negocio con su impacto en pesos, sus opciones y su prioridad, todo calculado. |
| `salud_negocio(negocio_id) → jsonb` | Cinco notas de 0 a 100 (ventas, márgenes, inventario, compras, riesgos) y el índice general. `NULL` si no hay datos para ninguna. |
| `ejecucion_preparar(ejecucion_id) → jsonb` | Devuelve hallazgos + prompt + plantilla en **una** llamada. Verifica el cupo contra `v_consumo_negocio` **antes** de dar el prompt: si se pasó, `{bloqueado:true}` y no gasta tokens. Si no hay prompt activo, `{error:'sin_prompt'}`. |
| `ejecucion_cerrar(ejecucion_id, estado, resultado jsonb) → jsonb` | Guarda texto, tokens, costo, PDF (base64→bytea) y libera la sesión. |
| `validar_cifras(texto, hallazgos jsonb) → jsonb` | Extrae con regex todos los números del texto y verifica que existan en los hallazgos. Devuelve `{ok, inventadas[]}`. Ignora números de 1–2 dígitos; recorta separadores de miles y puntuación final. **Las dos puntas se leen igual** (`055`): tanto el texto del modelo como los hallazgos se expanden con `cifra_variantes`, porque los hallazgos traen texto ya redactado por SQL con coma decimal (`fmt_decimal`) y el extractor viejo partía "142,3" en `142` y `3`. |
| `mantenimiento_ciclo() → jsonb` | Reaper (ver §7). Devuelve `{notificaciones:[{chat_id, respuestas}]}`. |
| `snapshot_tomar(negocio_id, origen, ejecucion_id) → bigint` | Fotografía el estado del negocio y lo guarda (upsert por día). Calcula desde las **vistas**, no desde `ejecuciones.hallazgos`. Devuelve NULL si el negocio no tiene un solo movimiento fechado. |
| `snapshot_anterior(negocio_id, antes_de) → jsonb` | El último estado registrado antes de esa fecha. Es la entrada de las reglas comparativas (B3). NULL si no hay historia. |
| `snapshot_version() → int` | Versión del contrato de `metricas`. Subirla es un solo cambio. |
| `snapshot_umbrales(negocio_id) → jsonb` | Todos los umbrales vigentes, con la fila del negocio ganándole a la global. |
| `snapshots_backfill() → int` | Reconstruye snapshots parciales desde `ejecuciones.hallazgos`. |
| `recomendaciones_negocio(negocio_id, registro) → jsonb` | El motor de reglas. Con `registro=false` (el defecto) devuelve lo que va al informe, con los topes de siempre. Con `true` devuelve **todo lo detectado**, sin topes y con `regla`/`clave_objeto`/`en_informe`. |
| `recomendaciones_registrar(negocio_id, ejecucion_id) → jsonb` | Persiste lo detectado, cierra lo que ya no está y marca lo que llegó al informe. Devuelve el conteo de cada cosa. |
| `recomendacion_objeto_evaluable(negocio_id, clave) → boolean` | ¿El objeto sigue teniendo movimientos visibles? Es lo que separa "se resolvió" de "lo perdí de vista". |
| `recomendaciones_vigentes(negocio_id, limite) → jsonb` | Las abiertas, con `dias_abierta` y `veces_vista`. La entrada de C1 y D1. |
| `informes_periodicos_disparar() → jsonb` | **El informe que nadie pidió** (`068`): crea sesión y ejecución para los negocios que ya vieron un informe, cargaron datos desde entonces y hace 30 días que no analizan. Devuelve el aviso previo y la ejecución a correr. |
| `v_negocios_informe_periodico` | A quién le toca. Nunca al que nunca vio un informe: el primero lo pide el dueño. |
| `alertas_evaluar() → jsonb` | **La proactividad** (`067`). Recorre `v_negocios_alertables`, evalúa las reglas y devuelve notificaciones con el contrato de siempre. Cero nodos nuevos: `mantenimiento_ciclo` las concatena y `wf_cron` las despacha. |
| `v_negocios_alertables` | Quién está en condiciones de recibir un aviso: hay a quién avisarle, autorizó (051), y **entraron datos después del último análisis**. |
| `recomendaciones_medir(negocio_id) → jsonb` | Llena el eje `resultado` (`066`): compara la magnitud de cada regla contra la foto tomada al cerrar. Solo mide si **llegaron** datos después del cierre (`creado_en`, no `fecha`). |
| `metricas_resultado` | Qué magnitud mira cada regla y hacia dónde debería moverse. Una tabla, no un algoritmo: medir una regla nueva es un INSERT. |
| `recomendacion_metrica_valor(...)` / `recomendacion_marcar_cierre(id)` | Leer una magnitud, y la foto que se guarda al cerrar. Sin esa foto no hay contra qué comparar. |
| `portal_factura_guardar(...)` | Alta manual de una factura por cobrar (`069`, F2). Reusa el tercero por nombre normalizado: sin eso, "Panadería El Sol" y "panaderia el sol" serían dos deudores y cada cartera se vería la mitad de grande. |
| `pedido_sugerido(negocio_id) → jsonb` | Las recomendaciones abiertas de "se agota", consolidadas en lista de compra con el proveedor más barato **al que ya le compró** y el costo estimado (`065`). Las unidades no se recalculan: son las que se le mostraron al dueño. |
| `v_proveedor_mas_barato` | El proveedor más barato conocido por producto. "Conocido" = de sus propias compras; Chasqui no tiene precios de mercado y no los inventa. |
| `recomendacion_accion(reco_id, negocio_id, accion, usuario_id) → jsonb` | **El único punto de escritura de las acciones** (`064`), para chat y portal. `hice` → resuelta · `no_aplica` → ignorada · `precio` → escribe el precio sugerido en `conocimiento` y cierra. Valida negocio y que siga abierta: un botón de un informe viejo no cierra nada dos veces. |
| `teclado_recomendaciones(negocio_id)` / `teclado_recomendacion(id)` | Los dos niveles de botones. El de acciones solo ofrece "aplicar precio" si hay un precio en `datos`. |
| `intencion_detectar(texto) → text` | Qué está preguntando el dueño, por patrones sobre `intenciones`. NULL si ninguna coincide, y eso no es un error: queda el contexto abierto de C1. |
| `periodo_resolver(texto, defecto, hasta) → jsonb` | La ventana temporal, resuelta a fechas concretas. El texto manda sobre el defecto de la intención; el ancla es la fecha más reciente de los datos, no el reloj. |
| `intencion_agregados(negocio_id, metrica, desde, hasta, producto, proveedor) → jsonb` | **Un** agregador para las siete métricas. Es lo que evita que `intenciones` sea un despachador de funciones. |
| `intencion_resolver(negocio_id, texto) → jsonb` | La intención de punta a punta: qué se pidió, sobre qué ventana, con qué filtros, contra qué se compara, y el resultado **ya calculado**. |
| `contexto_negocio_recuperar(negocio_id, ctx) → jsonb` | La `funcion_hallazgos` de `consulta` (`062`). Compone KB + perfil + salud + comparativo + recomendaciones vigentes. Reemplaza a `conocimiento_recuperar`, que solo miraba la KB (H2). |
| `v_perfil_negocio` / `perfil_negocio(negocio_id) → jsonb` | **El perfil consolidado** (`061`): lo estable del negocio —qué vende, a quién le compra, margen típico (mediana), estacionalidad, problemas recurrentes, acciones tomadas, calidad del dato—. Es el contexto estructurado que consume la Fase C. No es un informe ni un diagnóstico: no dice qué hacer. |

### 4.5 Router y admin

| Función | Qué hace |
|---|---|
| `router_procesar_mensaje(evento jsonb) → jsonb` | El cerebro de la conversación (ver §6.1). Devuelve `{chat_id, respuestas[], acciones[]}`. Desde `056` es un **despachador delgado** sobre los handlers de abajo; la firma y el contrato de salida no cambiaron. |
| `router_ctx(evento jsonb) → jsonb` | Arma el contexto del mensaje: parseo del texto y de los prefijos de botón (`svc:`, `mod:`, `modayuda:`, `tipo:`, `acepto:`), identidad (`usuario_de_canal`, que crea usuario y negocio si es la primera vez) y capacidades activas del sistema. |
| `router_h_admin(ctx) → jsonb` | Reportes de admin. Corre **antes** de leer la sesión: un `/salud` no debe refrescarle `ultima_actividad` a una sesión que estaba por expirar. |
| `router_h_comandos(ctx) → jsonb` | Comandos y botones que no dependen del estado: informativos, módulos, consentimiento, `tipo:`, `/portal`, `/plan`, `/saber`, `/cancelar`, `/nueva`, `svc:`. |
| `router_h_sin_sesion(ctx) → jsonb` | No hay conversación abierta: archivo suelto, pregunta libre o `sin_sesion`. |
| `router_h_intake(ctx) → jsonb` | Hay sesión y falta elegir servicio (match difuso por nombre o código). |
| `router_h_recibiendo(ctx) → jsonb` | Hay servicio elegido y entran archivos: `/todos`, `/faltan`, `/listo`. |
| `router_respuesta(chat, plantilla, vars, teclado, acciones) → jsonb` | Arma ese valor de retorno. Evita repetir quince veces el mismo `jsonb_build_object` y elimina de raíz el error de tipado de la migración 016 (literales `'{}'` entrando como `text`). Con `plantilla = NULL` devuelve solo acciones. |
| `admin_reporte(cmd) → text` | Formatea las vistas de operación como texto para Telegram (`/salud`, `/embudo`, `/fallas`, `/consumo`, `/matching`, `/pendientes`). |

**Botón y texto son el mismo camino.** Los `callback_data` de los teclados son
los propios comandos (`/nueva`, `/listo`, `/cancelar`, `acepto`), así que
`router_procesar_mensaje` no distingue un toque de un mensaje escrito: no hay dos
máquinas de estados que mantener sincronizadas. Los formatos propios son
`svc:<codigo>` (elegir servicio), `mod:<codigo>` (entrar a un módulo),
`modayuda:<codigo>` (qué hace ese módulo), `tipo:<codigo>` (naturaleza del
negocio), `acepto:<mensaje original>` (el consentimiento se lleva puesto el paso
que lo disparó, para poder retomarlo) y `rec:<accion>[:<id>]` (`064`: `list`,
`ver`, `hice`, `no_aplica`, `precio`; lo atiende `router_h_comandos`).

**La entrada, desde las migraciones 045-046.** `/start` y `/ayuda` devuelven
`sistema.bienvenida`: Chasqui se presenta como asistente, invita a escribir lo
que el usuario tenga en mente —eso cae en el servicio `consulta`— y ofrece un
único botón, "¿Qué puedo hacer?", que abre el menú del módulo. Entrar a un
módulo no abre sesión: es un menú. La sesión empieza al tocar un servicio, y un
`svc:` ya no necesita un intake abierto (antes solo funcionaba dentro de
`/nueva`). Antes de pedir archivos, `router_arranque_servicio` pregunta la
naturaleza del negocio si todavía no se sabe. El diseño completo está en
`docs/TELEGRAM_UX.md`.

Pasos que el router ya no pregunta (migración 024):

- con **un solo servicio activo**, `/nueva` no muestra el menú: arranca;
- un **archivo suelto sin sesión abierta** abre la sesión y se procesa, en vez de
  contestar "no tenés un análisis en curso" y obligar a reenviarlo.

Y estados que antes caían en "no te entendí" tienen respuesta propia
(`ejecucion.ya_en_curso`, `sistema.servicio_ya_elegido`). Eso hace inofensivos los
teclados viejos que quedan en el historial del chat: no hace falta borrarlos, un
botón rancio contesta algo sensato.

---

## 4.6 El informe prescriptivo (migración 047)

Un informe que dice "el costo de la panela subió 10,53%" entrega un dato. El que
sirve entrega una decisión: qué pasó, **cuánto cuesta**, qué opciones hay y qué
tan urgente es. Esas cuatro respuestas las produce `recomendaciones_negocio`, en
SQL, y el modelo solo las redacta.

**Por qué el cálculo no puede estar en el modelo.** `validar_cifras` rechaza el
informe si aparece un número que no esté en los hallazgos, así que un impacto
"estimado" por el LLM tumbaría la entrega y caería al informe seco. Y una
recomendación es una **regla**: una consulta que se puede leer, ajustar por
`parametros` y auditar, no una frase que el modelo improvisa distinto en cada
corrida.

Las reglas de hoy (todas Nivel 1: solo el historial del propio negocio):

| Regla | Dispara cuando | Qué calcula | `impacto_tipo` |
|---|---|---|---|
| Costo al alza | `deriva_pct ≥ deriva_costo_alerta_pct` | Sobrecosto mensual, margen resultante, precio de venta que recupera el margen mínimo, proveedor más barato si lo hay | `mensual` |
| Proveedor más caro | Se le compró a varios y el promedio supera al mejor en 5% | Ahorro mensual y a quién comprarle | `mensual` |
| Margen bajo | `margen_pct < margen_minimo_pct` | Utilidad no ganada por mes y precio que llega al mínimo | `mensual` |
| Se agota | `dias_cobertura < dias_cobertura_min` | Venta en riesgo y **cuántas unidades pedir**: `(dias_entrega_proveedor + dias_stock_seguridad) × unidades_por_día` | `unico` |
| Plata quieta | `dias_cobertura > rotacion_lenta_dias` | Capital inmovilizado; si el margen es alto propone promocionar en vez de rematar | `capital` |
| Dependencia | Un proveedor concentra ≥ `dependencia_proveedor_pct` del gasto | Riesgo, sin impacto en pesos | `mensual` (impacto 0) |
| **Dejó de venderse** (`060`) | Un producto con ≥ `ventas_minimas_historicas` lleva > `dias_sin_venta_alerta` sin una venta | Lo que entraba por mes cuando se vendía | `mensual` |
| **El proveedor viene subiendo** (`060`) | El mismo proveedor subió el precio ≥ `subidas_proveedor_alerta` veces en el último año | El sobrecosto mensual acumulado y con quién negociar | `mensual` |
| **El margen se viene cayendo** (`060`) | Margen actual < snapshot anterior < el de antes, con caída ≥ `caida_margen_pp_alerta` puntos | La utilidad mensual perdida y el precio que la recupera | `mensual` |
| **Vendés menos que el año pasado** (`060`) | El último mes completo cae ≥ `caida_anual_pct_alerta` contra el mismo mes del año anterior | La diferencia en pesos | `mensual` |
| **Te deben y ya venció** (`069`) | Un cliente con saldo vencido hace ≥ `cartera_mora_dias` | El **saldo vencido**, no el total que debe | `capital` |

Las cuatro últimas son **comparativas**: miran la película, no la foto. Tres se
calculan sobre `mov_visibles` y no sobre snapshots, a propósito — un hecho que
está en los movimientos (cuándo fue la última venta, qué precio pagó cada
compra) es más preciso ahí y no depende de cada cuánto se corrieron análisis.
Solo el margen necesita snapshots, porque un margen no es un hecho registrado
sino una **medición**: sale de comparar costo y precio vigentes en un momento, y
ese momento hay que haberlo guardado.

**El "hoy" de una regla comparativa es la fecha más reciente de los datos, no
`current_date`.** Un negocio que sube en agosto un archivo que termina en mayo
no lleva tres meses sin vender: lleva tres meses sin cargar. Medir contra el
reloj convertiría cada carga atrasada en una avalancha de alertas falsas.

Dos topes que importan: cada regla aporta **como mucho 2** problemas (sin eso, un
negocio con veinte productos por agotarse llenaba el informe con la misma regla y
el dueño no se enteraba de que además pierde margen), y la lista entera se corta
en 8. La **prioridad** es relativa: el impacto medido contra lo que mueve el
negocio en un mes, porque $80.000 es enorme para una tienda y ruido para una
distribuidora.

**Los impactos no son todos la misma cosa** (`055`). Tres de las reglas dan pesos
*por mes* que se van a seguir yendo; "se agota" da pesos *una sola vez* —el ciclo
de entrega que se pierde si el producto falta—; y "plata quieta" no da una
pérdida en absoluto, sino un **stock**: capital que sigue siendo del negocio,
solo que inmóvil. Un acumulado casi siempre es el número más grande, así que
mientras los tres compitieron en el mismo ranking, la plata quieta encabezaba el
informe por aritmética y no por criterio.

Por eso `recomendaciones_negocio` publica `impacto_tipo ∈ {mensual, unico,
capital}` y cada tipo tiene su propia vara, siempre relativa a lo que el negocio
mueve en un mes:

| `impacto_tipo` | Alta | Media | Parámetros |
|---|---|---|---|
| `mensual` | ≥ 2% | ≥ 0.5% | `prioridad_alta_pct`, `prioridad_media_pct` |
| `unico` | ≥ 10% | ≥ 3% | `prioridad_alta_unico_pct`, `prioridad_media_unico_pct` |
| `capital` | ≥ 50% | ≥ 20% | `prioridad_alta_capital_pct`, `prioridad_media_capital_pct` |

Dentro de una misma prioridad el orden **no** es por el monto crudo, sino por
cuántas veces cada recomendación supera el umbral *media de su propio tipo*: es
lo único comparable entre un flujo y un stock.

El **índice de salud** (`salud_negocio`) va arriba del informe y no pasa por el
modelo en ningún momento. Cada nota se calcula sobre lo que hay: si el negocio no
cargó ventas, la nota de ventas es `NULL` y no entra al promedio —inventar un 0
sería mentir—.

**El informe seco dejó de ser un consuelo.** Cuando el modelo falla dos veces,
`informe_estructura_seca` arma los mismos bloques directamente desde
`recomendaciones`: se pierde la redacción, no el contenido. Es la mejor prueba de
que el valor no lo pone el modelo.

**Niveles 2 y 3** (comparar contra precios oficiales tipo SIPSA, y contra el
resto de negocios anonimizados) están en `docs/PLAN_PRODUCCION.md`. El contrato
de `recomendaciones_negocio` no cambia: cambia de dónde sale el comparativo.

---

## 5. Ingesta DIAN (UBL 2.1) en detalle

La factura electrónica colombiana es UBL 2.1 con cinco tipos de documento:
`Invoice`, `CreditNote`, `DebitNote`, `ApplicationResponse` y `AttachedDocument`.

**El detalle que rompe a casi todos:** lo que el cliente recibe por correo suele
ser el `AttachedDocument`, un contenedor donde el `Invoice` real va embebido como
**CDATA** dentro de `cac:Attachment//cbc:Description`. `ingesta_parsear_dian`:

1. Lee el nodo raíz con `xpath('local-name(/*)', xml)`.
2. Si es `AttachedDocument`, extrae el `text()` de la `Description` (que serializa
   el CDATA con sus marcadores) y los recorta con regex
   (`^<!\[CDATA\[` … `\]\]>$`), recasteando a `xml`. Vuelve a leer la raíz.
3. Según la raíz elige el tag de línea: `InvoiceLine` / `CreditNoteLine` / `DebitNoteLine`.
4. Cabecera y totales con `xpath` + `local-name()` (evita pelear con los namespaces):
   `cbc:ID`, `cbc:IssueDate`, proveedor vía `AccountingSupplierParty//RegistrationName`,
   `LegalMonetaryTotal/PayableAmount`, `TaxTotal/TaxAmount`.
5. Líneas con `XMLTABLE` (namespaces `cac`/`cbc` declarados): descripción, código
   (`StandardItemIdentification/ID`), cantidad + `@unitCode`, `LineExtensionAmount`,
   `Price/PriceAmount`. Cada línea → un `movimiento` tipo `compra`.
6. Control de cuadre: devuelve `cuadra = |Σ líneas + impuesto − PayableAmount| < 1`.

Requisito verificado: este Postgres tiene libxml (`xpath()` y `XMLTABLE` funcionan).

> **Riesgo abierto:** los fixtures de `docs/ejemplos/` son sintéticos (anexo técnico
> 1.9 de la DIAN). Los totales cuadran contra los propios fixtures, **no contra un
> XML real de cliente**. Re-verificar en cuanto haya facturas reales.

---

## 5.4 La memoria del negocio (snapshots)

Chasqui miraba siempre el presente: `hallazgos_generar` calculaba sobre los
movimientos de hoy, entregaba el informe y lo medido se perdía. Desde la `058`,
**cada análisis que cierra bien deja registrado cómo estaba el negocio ese día**.

Un snapshot es **estado empresarial, no una copia del informe**. La distinción
es lo que lo hace útil dentro de un año: el informe va a cambiar de diseño
varias veces, y los snapshots tienen que seguir siendo comparables entre sí.

| Contiene | No contiene |
|---|---|
| Márgenes por producto (**todos**, no solo los que dispararon regla) | Texto narrado |
| Coberturas, stock y su `origen_stock` | HTML, secciones, iconos |
| Gasto por proveedor y precio por producto+proveedor | Recomendaciones (eso es B2) |
| Unidades vendidas por producto | Comparaciones (eso es B3) |
| Totales del periodo y `base_mes` | |
| Las cinco notas de salud | |
| Calidad del dato con que se midió (matching, stock estimado) | |
| **Los umbrales vigentes ese día** | |

Los dos últimos existen por la misma razón: un snapshot tiene que declarar bajo
qué condiciones se midió. Una nota de salud que baja porque alguien cambió
`margen_minimo_pct` no es un deterioro del negocio, y una medición hecha con el
40% de la plata sin producto resuelto (`057`) no es comparable con una limpia.

**Se calcula desde las vistas, no desde `ejecuciones.hallazgos`.** Esa columna
ya persiste el JSON de cada corrida desde la `001` y sirve de material para el
backfill, pero no sirve *como* snapshot: su forma cambió cuatro veces (025, 029,
043, 047) porque es la entrada de un prompt, no un contrato; y guarda solo los
productos que dispararon una regla, que es justo lo contrario de lo que hace
falta para detectar un deterioro. De ahí la columna `version`.

**Cuándo se toma**: en `ejecucion_cerrar`, si el estado es `completada` y el
servicio es de `entrada='archivos'`. No para `consulta` —preguntar algo no
cambia el estado del negocio— ni para ejecuciones fallidas. Si tomarlo falla,
se registra en `fallas` y la ejecución se cierra igual: un informe entregado
vale más que una foto perfecta.

**Los snapshots del backfill son parciales y lo dicen** (`metricas.parcial` y
la lista `faltan`). Lo que sí se puede reconstruir se escribe con la forma del
contrato v1; lo que no —el Pareto y los productos que dispararon regla, que en
los hallazgos vienen con nombre y no con `producto_id`— va con nombre propio
(`pareto_parcial`, `margen_bajo_parcial`, …) para que nadie lo confunda con las
claves de v1.

---

## 5.5 Las recomendaciones se acuerdan de sí mismas

Hasta la `059`, `recomendaciones_negocio` calculaba, el informe mostraba, y se
tiraba todo. Chasqui repetía el mismo consejo cada mes sin saber que ya lo había
dado, no podía decir "esto te lo dije en marzo y sigue igual", y D1 (los botones
*Ya lo hice* / *No aplica*) no tenía contra qué escribir.

**La identidad de una recomendación es `(negocio, regla, objeto)`.** "El costo de
ACEITE subió" es la misma recomendación en marzo y en abril. Por eso las seis
CTEs publican `clave_objeto` (`producto:<id>` o `proveedor:<nombre>`): hasta acá
lo único que la identificaba era el nombre del producto en `titulo`, que ni es
estable ni es único.

**Dos ejes, separados desde el diseño.** `estado` responde *¿qué pasó con la
recomendación?* y nada más:

| `estado` | Significa |
|---|---|
| `nueva` | Detectada, pero todavía no llegó a ningún informe |
| `vigente` | Ya se mostró y se sigue detectando |
| `resuelta` | El problema ya no está (`cerrada_por` dice si por dato o por acción del usuario) |
| `ignorada` | El dueño dijo que no aplica |
| `caducada` | Dejó de poder evaluarse: el objeto desapareció de los datos |

El eje de **resultado** (¿sirvió?) es otro y lo llena D3. La columna `resultado`
queda creada, en NULL y con su CHECK, precisamente para que a nadie se le ocurra
meter `sirvio`/`no_sirvio` dentro de `estado`.

**`resuelta` ≠ `caducada`.** Que una recomendación abierta no se detecte hoy
puede deberse a dos cosas opuestas: el problema se arregló —el costo bajó, el
stock se repuso: las reglas *sí* evaluaron el objeto y no dispararon— o dejó de
poder verse, porque el producto no tiene un solo movimiento en la ventana
visible. Lo segundo no es haberlo resuelto, y decirlo así sería mentirle al
dueño. Los separa `recomendacion_objeto_evaluable`.

**Por qué el registro pide `p_registro=true`.** Los topes del informe (2 por
regla, 8 en total) esconden problemas reales. Si el registro usara la salida del
informe, una recomendación empujada fuera del top 8 se cerraría como *resuelta*
sin que nada se hubiera arreglado. En modo registro salen **todas** las
detectadas, cada una con `en_informe` para saber cuál llegó de verdad al dueño —
que es lo único que puede contar como "vista".

**El modo informe no cambió.** Ese JSON es lo que ve el modelo y lo que audita
`validar_cifras`; no tiene por qué enterarse de una clave interna como
`producto:9`. `recomendaciones_negocio(negocio_id)` devuelve byte a byte lo
mismo que antes de la `059`.

**Y `recomendaciones_negocio` sigue siendo pura.** El roadmap decía "pasa de
función pura a función + upsert"; se implementó como función pura +
`recomendaciones_registrar` porque (1) es `STABLE` y la llama `hallazgos_generar`,
que a su vez llama `ejecucion_preparar` — volverla `VOLATILE` obliga a desmarcar
toda la cadena; (2) preguntar no debería escribir: el portal puede querer
previsualizar sin registrar; (3) probarla dejaría de ser gratis. El registro
corre en `ejecucion_cerrar`, junto al snapshot y por la misma razón: es cuando
de verdad se le entregó algo al dueño. Si falla, queda en `fallas` y la
ejecución se cierra igual.

---

## 5.6 Preguntar a los números (Fase C)

El servicio `consulta` no pide archivos: se dispara escribiendo. Hasta la `062`
cortaba antes de arrancar si la KB no tenía una FAQ parecida — a un negocio con
quince meses de facturas cargadas le contestaba *"todavía no tengo eso
cargado"*. Hoy la compuerta arranca si hay KB **o** si hay números.

**El contexto lo compone SQL, no el prompt.** `contexto_negocio_recuperar` junta
lo que la Fase B construyó: la KB (un precio cargado a mano le gana a cualquier
agregado cuando la pregunta es por eso), el perfil (`061`), la salud de hoy, el
comparativo (`060`) y las recomendaciones vigentes (`059`). Son ~5 KB de
contexto, todo calculado.

> **El presupuesto de salida es parte del contrato del contexto.** Con
> `max_tokens = 900` —el valor de cuando el contexto era una lista de FAQs— el
> modelo gastaba todo razonando sobre 5 KB y devolvía `finish_reason: length`
> con `content: ""`. Subido a 3000, no a 8000 como los informes: la respuesta
> sigue siendo corta, lo que hace falta es lugar para pensar. Si crece uno, hay
> que revisar el otro.

**Los agregados puntuales son C2.** "¿Cuánto vendí en marzo?" no se puede
contestar con un contexto general, y el prompt tiene prohibido calcular. La
cadena:

```
intencion_detectar(texto)     → qué se preguntó, por patrones sobre `intenciones`
periodo_resolver(texto, …)    → la ventana, resuelta a fechas concretas
intencion_agregados(…)        → UN agregador para las siete métricas
intencion_resolver(…)         → todo junto, con el resultado ya calculado
```

Cuatro decisiones que sostienen el diseño:

- **La detección es determinística**, no una llamada al modelo. Un patrón que
  falla se arregla con un UPDATE a un array; un clasificador que falla se
  arregla peleando con un prompt. Si algún día los patrones no dan, el modelo
  puede entrar **solo como desempate** — nunca como el que decide qué se calcula.
- **Un agregador, siete métricas.** Es lo que evita que `intenciones` se
  convierta en un despachador de funciones y que cada pregunta nueva sea código.
- **El ancla temporal es la fecha más reciente de los datos**, no el reloj, por
  la misma razón que en las reglas comparativas. Y los nombres de mes se buscan
  como palabra completa (`\y`): "mayo" dentro de "Mayorista Centro" hacía que
  *"¿cuánto le compré a Mayorista Centro?"* se respondiera con las compras de
  mayo, con total seguridad y sin avisar de nada.
- **Filtrar por producto usa `word_similarity`, no `similarity`.** La pregunta es
  larga y el nombre corto: comparar las cadenas enteras castiga al producto por
  el largo de la pregunta ("yogurt" vs. "¿cuánto stock me queda de yogurt?" daba
  0,167; con `word_similarity`, 0,412).

**"No tengo datos de entonces" ≠ "vendiste $0".** Una ventana sin un solo
movimiento se marca `sin_datos` con su nota, porque un total en cero suena a que
el negocio se hundió. Y las cifras viajan **también formateadas**
(`total_txt`, `utilidad_txt`): si el modelo formatea por su cuenta produce una
cifra que no está en el contexto y `validar_cifras` la rechaza.

---

## 5.7 Del consejo a la acción, y a la medición (Fase D)

`recomendacion_accion` es **el único punto de escritura** de las acciones, para
chat y portal: `hice` → resuelta · `no_aplica` → ignorada · `precio` → escribe el
precio sugerido en `conocimiento` y cierra. Valida el negocio y que la
recomendación siga abierta, así que un botón de un informe viejo no cierra nada
dos veces.

**Los botones no viajan dentro del informe, y no es una limitación.** El informe
se arma en `ejecucion_preparar` y las filas de `recomendaciones` recién existen
al cerrar (`059`): en el momento del render no hay a qué apuntar. Además el
teclado topa en 6 filas (§6.4) y ocho recomendaciones por tres acciones son
veinticuatro. Entonces `ejecucion.entregada` lleva **un** botón —*"✅ Ya hice
algo"*, `rec:list`— y todo lo demás se resuelve al tocarlo, contra la tabla ya
escrita. El mismo camino sirve para el portal y para WhatsApp sin cambiar nada.

**El precio sugerido dejó de vivir dentro de una frase.** Las CTEs publican
`datos` (`precio_sugerido`, `unidades_pedir`, `proveedor_sugerido`): aplicar el
precio parseando *"Subilo a $12.500"* habría sido depender de un texto que se
reescribe cualquier día. De ahí sale también la cantidad que consume D2.

**La lista de pedido** (`pedido_sugerido`, `065`) consolida las recomendaciones
abiertas de *se agota*. Tres reglas:

- **Las unidades no se recalculan.** El dueño vio "pedí 7" el martes; si el
  jueves la lista dice 9 porque entró una venta, deja de creerle a las dos
  cifras. La lista muestra lo que se le recomendó.
- **El proveedor más barato es el más barato CONOCIDO** (`v_proveedor_mas_barato`,
  de sus propias compras). Chasqui no tiene precios de mercado y no los inventa.
- **El total declara lo que le falta.** Un producto sin precio conocido no entra
  al total y `sin_precio` lo cuenta: presentarlo como el total de la compra sería
  mentir por omisión. Cada renglón arrastra `stock_estimado` (A2).

**El resultado es un segundo eje, no un estado más** (`066`). "Aplicar el precio
sugerido" puede quedar perfectamente ejecutada —`estado = resuelta`,
`cerrada_por = accion_usuario`— y aun así dar resultado **negativo**: subió el
precio y dejó de vender. Colapsarlos en una columna haría imposible distinguir
"me hicieron caso" de "les fue bien".

Se mide sin inventar un modelo: `metricas_resultado` dice qué magnitud mira cada
regla y hacia dónde debería moverse; al cerrarse se guarda el valor
(`recomendacion_marcar_cierre`) y cuando entran datos nuevos se relee y se
compara (`recomendaciones_medir`). Un cambio menor que el umbral es `neutro`.

> **La compuerta mira `creado_en`, no `fecha`.** Un archivo con ventas fechadas
> la semana que viene ya estaba cargado cuando se cerró la recomendación, así que
> no dice nada sobre si la acción sirvió. Lo que importa es que haya **entrado**
> información nueva. Con el gate mal, todo se medía de inmediato contra sí mismo
> y daba `neutro`.

Lo que no se mide, se dice: `sin_medir` se cuenta en el perfil y el portal
muestra "sin medir todavía".

---

## 5.8 Proactividad: alertas e informe periódico (Fase E)

**La regla que gobierna la `067` no es "avisar" sino "no molestar"**: un bot que
avisa de más lo silencian, y silenciado no sirve para nada. Las cinco compuertas
de `alertas_evaluar` son todas para NO avisar:

| Compuerta | Parámetro | Por qué |
|---|---|---|
| Solo prioridad **alta** | — | Lo demás espera al informe |
| **Un** aviso por negocio y corrida | `alerta_max_por_corrida` (1) | Nunca una ráfaga |
| Cooldown por regla+objeto | `alerta_cooldown_dias` (14) | El mismo problema no se avisa dos veces seguidas |
| Horario del negocio | `alerta_hora_desde/hasta` (8–20), `zona_horaria` | Un aviso a las 3 AM es la forma más rápida de que lo bloqueen |
| Solo con datos nuevos | `v_negocios_alertables` | Sin datos nuevos no hay nada que el dueño no haya visto |

**El aviso avisa y ofrece; no registra.** Lleva un hallazgo real —calculado con
la misma función que el informe— y dos botones (*ver el análisis completo*, *ya
hice algo*), y deliberadamente **no** escribe en `recomendaciones` ni toca
`vista_en`: eso solo pasa cuando hay un informe de verdad, o `veces_vista`
contaría mensajes que no son informes.

**Cero nodos nuevos en E1**: `mantenimiento_ciclo` concatena las notificaciones a
las suyas y `wf_cron` las despacha con el fanout que ya tenía desde la `016`. Con
su guardarraíl: si evaluar las reglas revienta, el reaper —que es lo que no puede
dejar de correr— ya hizo su trabajo y sus notificaciones salen igual.

**El informe periódico (`068`) sí necesitó un nodo**, y es inevitable: una alerta
es un mensaje y `wf_cron` ya sabía mandarlos; un informe es una **ejecución** y
hay que llamar a `wf_ejecutar`. `mantenimiento_ciclo` pasó a devolver dos listas
—`notificaciones` y `ejecuciones`— y el contrato viejo no cambió: quien solo lea
`notificaciones` sigue funcionando.

`v_negocios_informe_periodico` decide a quién le toca: **nunca al que nunca vio
un informe** (el primero lo pide el dueño, y así aprende qué es), solo si pasaron
`informe_periodico_dias` (30) y entraron al menos `informe_periodico_min_movs`
(10) movimientos desde entonces. Un aviso corto va **antes** del informe: uno que
aparece sin explicación se lee como spam por bueno que sea.

> `wf_cron` no se puede correr con `n8n execute --id`: su disparador es de agenda
> y no de sub-workflow. Se prueba llamando a `mantenimiento_ciclo()` directo, que
> es donde está toda la lógica.

---

## 5.9 Cartera como señal de liquidez (Fase F)

La cartera estaba clasificada como **ERP-DRIFT** y se justificaba **solo** si
alimentaba `recomendaciones_negocio`. La `069` la convierte en la regla número
once y en el sexto frente de `salud_negocio`.

**Es `capital`, no una fuga.** Una factura vencida no es plata que se pierde: es
plata que es tuya y no está — el mismo caso que "plata quieta", solo que en la
calle en vez de en la bodega. Comparte tipo de impacto y umbrales (`055`);
tratarla como fuga mensual la pondría siempre arriba de todo, que es el error que
A3 vino a arreglar.

**El impacto es el saldo VENCIDO, no el total que el cliente debe.** Se detectó
probando, con un cliente que debe $9.200.000 de los cuales solo $200.000 están
vencidos: con el total, el impacto habría sido 46 veces el real y habría
encabezado el informe. `v_cartera_tercero` no separa las dos cosas, así que la
cuenta se hace en la regla, y el texto menciona aparte lo que todavía no vence.

**Liquidez sigue la regla de las otras cinco notas: NULL si no hay datos.** Un
negocio que vende todo de contado no ve bajar su índice por una nota que no le
aplica.

**F2 (el alta manual) no era opcional**: `facturas` solo se llenaba desde XML de
la DIAN, así que quien carga CSV nunca tenía una factura y por lo tanto nunca
recibía la recomendación.

---

## 5.10 El portal (PostgREST)

El portal es **HTML estático + PostgREST**. No hay backend propio: el navegador
llama RPC `portal_*` y toda la autorización vive en Postgres.

**Tres roles, y por qué son tres** (`bin/preparar-portal.sh`, que corre como
superusuario porque `CREATE ROLE` no está al alcance del dueño de la base y por
eso no puede ser una migración):

| Rol | Puede |
|---|---|
| `authenticator` | Nada propio. `NOINHERIT`; lo único que hace es `SET ROLE` a los otros dos. Es con el que se conecta PostgREST. |
| `portal_anon` | Solo `portal_sesion_abrir` (y la cotización pública). |
| `portal_usuario` | Solo las RPC `portal_*`. |

**Magic link.** `/portal` en el chat llama a `portal_token_crear`, que devuelve un
token de **un solo uso** con 15 minutos de vida (en la base se guarda el hash, no
el token). El navegador lo canjea con `portal_sesion_abrir`, que lo marca usado y
firma un JWT con `app.settings.jwt_secret` — el mismo secreto que verifica
PostgREST, que nunca se persiste. La identidad sigue siendo la cuenta de
Telegram: no hay contraseñas.

**Ninguna función es pública por defecto.** Postgres da `EXECUTE` a `PUBLIC` en
toda función nueva, y `ALTER DEFAULT PRIVILEGES … IN SCHEMA` **no** lo quita:
cada migración que agrega una RPC del portal tiene que revocar y otorgar
explícitamente, y terminar con `NOTIFY pgrst, 'reload schema'` para que PostgREST
vea la firma nueva.

**Cada RPC deriva el negocio de la sesión** (`portal_negocio()`), nunca de un
parámetro: por eso `portal_alias_confirmar` o `portal_recomendacion_accion`
pueden delegar en la misma función que usa el router sin abrir un boquete.

Las cinco pestañas y de dónde salen:

| Pestaña | RPC principales |
|---|---|
| 🏪 Mi negocio | `portal_perfil`, `portal_movimientos_resumen` |
| 📈 Ventas | `portal_movimientos`, `portal_cartera`, `portal_factura_guardar`, `portal_pago_registrar`, `portal_conteos`/`portal_conteo_guardar`, `portal_pendientes`/`portal_alias_confirmar`, `portal_documentos` |
| 🏷️ Precios | `portal_conocimiento*`, `portal_cotizacion*` |
| 💡 Conocimiento | `portal_conocimiento*` |
| 📊 Informes | `portal_recomendaciones`/`portal_recomendacion_accion`, `portal_pedido`, `portal_snapshots`, `portal_informes`/`portal_informe` |

> **Los resultados se entregan en el portal, no en PDF.** Gotenberg y
> `plantillas_pdf` se dieron de baja en la `057`; un documento entregable
> (una cotización, por ejemplo) se decide caso a caso.

---

## 6. Los 7 workflows

Todos se generan con `bin/gen_wf_*.py` (+ `bin/wf_lib.py`) y se importan con
`n8n import:workflow`. Los IDs de credencial (`chasquiPg…`, `chasquiTg…`,
`chasquiDs…`) están fijos en los generadores.

### 6.1 wf_router — entrada

`Webhook /telegram` → `Normalizar` (verifica el secreto de la cabecera y
normaliza el update) → `EsBoton?`:
- toque de botón → `Responder` (`answerCallbackQuery`) → `Router`
- mensaje escrito → `Router`

→ `Router` (`router_procesar_mensaje`) → `Despachar` (separa respuestas de
acciones) → `Switch`:
- `enviar` → wf_enviar
- `ingerir` → wf_ingesta
- `ejecutar` → wf_ejecutar → wf_enviar (manda el informe)

`Normalizar` mapea `callback_query.data` al mismo campo `texto` que un mensaje,
así que el router atiende los dos igual. `Responder` existe porque Telegram deja
el botón con el relojito girando hasta que se le contesta el callback; va sin
texto, solo apaga el reloj. Es el **único** nodo de la ruta de salida con
`onError: continueRegularOutput`, y se justifica: un `callback_id` vencido
devuelve 400 `query is too old` y eso no puede impedir que el mensaje se procese.
Lo que se pierde ahí es un relojito, no una respuesta al usuario.

> **El secreto del webhook queda embebido** en el código de `Normalizar`. Generar
> sin el `.env` cargado produce un workflow que compara contra `''` y **rechaza
> todos los updates en silencio**: el bot deja de contestar y no hay error en
> ninguna parte. `gen_wf_router.py` aborta si falta `TELEGRAM_WEBHOOK_SECRET`.

**Por qué Webhook y no Telegram Trigger:** el Telegram Trigger auto-registra su
propio webhook al activar el workflow y lo re-apunta a `WEBHOOK_URL`. Con el quick
tunnel esa URL cambia en cada reinicio. Un Webhook en ruta fija + el `registrador`
(que re-apunta el webhook cuando el túnel cambia) sobrevive los reinicios sin
tocar nada.

La máquina de estados de `router_procesar_mensaje`. Desde `056` cada bloque vive
en su propio handler y el despachador solo decide el orden; a la derecha, quién
contesta cada cosa:

```
/salud,/embudo,…          → admin_reporte (solo rol=admin)      h_admin
   ── acá se lee la sesión y se le marca ultima_actividad ──    (despachador)
/start,/help,/ayuda       → bienvenida                          h_comandos
/comofunciona,/privacidad → informativos (accesibles SIN autorizar)   ″
(sin autorización)        → pide "acepto"; al aceptar, marca autorizacion_datos
/cancelar                 → cierra la sesión abierta (o sin_sesion si no hay)
/nueva                    → cierra sesiones previas; con 1 servicio activo va
                            directo a recibiendo(cargar_archivos), si no abre
                            intake(elegir_servicio) con teclado_intake()
sin sesión + documento    → con 1 servicio: abre sesión y {ingerir}; si hay
                            varios, pregunta cuál                h_sin_sesion
sin sesión                → sin_sesion                                ″
estado procesando         → ejecucion.ya_en_curso (bloquea la segunda corrida)
intake + svc:<codigo>     → recibiendo(cargar_archivos)          h_comandos
intake + texto            → match difuso del servicio            h_intake
recibiendo + documento    → acción {ingerir, sesion_id}          h_recibiendo
recibiendo + svc:<codigo> → servicio_ya_elegido (teclado viejo del historial)
recibiendo + /listo       → si hay docs parseados: crea ejecucion(preparando),
                            acción {ejecutar, ejecucion_id}            ″
rec:list|ver|hice|…       → lista/detalle/acción sobre una recomendación
                            (064, `recomendacion_accion`)       h_comandos
texto libre sin sesión    → servicio `consulta`: pregunta sobre los números
                            (062/063)                          h_sin_sesion
fallback                  → no_entendido                        (despachador)
```

**Cómo se extiende.** Un handler devuelve `NULL` para decir "esto no me toca,
seguí"; nunca se confunde con una respuesta real, porque `router_respuesta`
construye siempre un objeto. Todos reciben **un solo argumento** (`ctx jsonb`),
así que agregarle un dato al contexto no cambia ninguna firma ni obliga a
repuntar los handlers que no se enteraron — el contrato es un dato, como en
`servicios.funcion_hallazgos` y en `plantillas`. Una fase que cambie una
conversación reemplaza **su** handler; una que agregue un estado agrega un
handler y tres líneas al despachador. Antes de `056` cualquiera de las dos
obligaba a pegar las 356 líneas enteras del router, y así fue como la `051`
borró sin querer el `periodo` que la `046` había agregado.

El menú de comandos del botón azul (`setMyCommands`) lo registra
`bin/registrar-webhook.sh` junto con el webhook. Es la única entrada que Telegram
no permite poner como botón dentro de un mensaje, así que lleva lo que hace falta
cuando el usuario se pierde; el resto de la conversación va por botones.

### 6.2 wf_ingesta — archivos

`BajarArchivo` (Telegram, resource file) → `Empaquetar` (binario→base64, conserva
el binario) → `Registrar` (`ingesta_registrar_documento`, negocio derivado de la
sesión) → `Reconocido?` → `RequiereTabla?`, que abre las dos ramas:

- **documento** → `Procesar` (`ingesta_procesar_documento`, parsea el bytea).
- **tabular** → `RecuperarBinario` → `EsCSV?` → `ExtraerCSV` o `ExtraerHoja`
  (Extract From File) → `AgruparFilas` (filas + cabeceras + muestra de 5) →
  `Identificar` (huella) → `Inferir?`:
  - huella conocida → `CargarTabular`.
  - huella nueva → `ArmarMapeo` → `InferirMapeo` (DeepSeek) → `LeerMapeo` →
    `RegistrarFormato` → `CargarTabular`.

Ambas ramas confluyen en `Resolver` (`match_resolver_documento` +
`ingesta_resumen_documento`) → `Respuesta` (`ingesta.ok`,
`ingesta.formato_nuevo` o `ingesta.error_archivo`) → wf_enviar. La salida de
error de la descarga y la de archivo no soportado tienen su propia rama, que
avisa con el motivo real sin matar la sesión.

> **`RecuperarBinario` no es decorativo.** Los nodos Postgres descartan el
> binario: sus items solo llevan `json`. Sin volver a colgar el binario de
> `Empaquetar`, el nodo de extracción falla con *"expects the node's input data
> to contain a binary file 'data'"* y **todo CSV subido por el chat se rompe**.
> La rama XML no lo notaba porque parsea desde el `bytea` y nunca vuelve a
> necesitar el archivo.

El LLM de esta rama solo ve **nombres de columnas y 5 filas de muestra**:
infiere el `mapeo`, nunca las cifras. Las cifras las carga Postgres con ese
mapeo, así que no hay números inventados en `movimientos`, el costo no depende
del tamaño del archivo, y el resultado es una fila auditable y corregible a
mano.

### 6.3 wf_ejecutar — el motor genérico

No sabe qué servicio corre. `Inicio` (recibe `ejecucion_id`) → `CanalChat` →
`EsTelegram?` → `Escribiendo` (`sendChatAction: typing`, con `onError`
continue: que no se pinte el indicador no puede frenar un análisis) →
`Preparar` (`ejecucion_preparar`) → `Bloqueado?` (cupo/sin-prompt → respuesta temprana) →
`ArmarLLM` (inyecta hallazgos en el prompt, `response_format: json_object`) →
`DeepSeek1` → `Extraer1` → `Render1` (`informe_render`) → `Validar1`
(`validar_cifras`) → `Cifras1ok?`:
- ok → `TextoOK`
- no → **reintento único**: `DeepSeek2` → `Extraer2` → `Render2` → `Validar2` → `Cifras2ok?`:
  - ok → `TextoOK2`
  - no → `EstructuraSeca` → `RenderSeco` → `TextoSeco`

Confluencia en `Consolidar` → `Cerrar` (`ejecucion_cerrar` con texto+tokens) →
`RespFinal` (parte el informe en mensajes de chat). El PDF quedó fuera del camino;
Gotenberg y `plantillas_pdf` se dieron de baja en la `057`: hacía ocho
migraciones que nadie volvía atrás, y `ejecucion_preparar` seguía consultando
la tabla en cada corrida para publicar un dato que ya nadie leía.

> El indicador "escribiendo…" va **en la cadena**, no como rama paralela: un
> sub-workflow le devuelve al padre la salida del **último nodo ejecutado**, y
> una rama suelta puede quedarse con ese lugar y dejar a `wf_enviar` sin informe
> que mandar. Por eso también `Preparar` lee `ejecucion_id` de `$('Inicio')` y
> no de `$json`: el item que le llega ya no es el del trigger.

**El modelo no escribe el informe formateado: devuelve estructura.**

```json
{ "titular": "…",
  "hallazgos": [ {"icono":"📈","titulo":"…","problema":"…","impacto":"…",
                  "opciones":["…"],"prioridad":"alta"} ],
  "acciones": ["…"] }
```

Desde la 047 el modelo redacta los bloques que ya calculó
`recomendaciones_negocio` (§4.6); `informe_render` sigue aceptando la forma
vieja (`secciones[]` con `puntos[]`) para los servicios que no tienen motor de
reglas.

`informe_render` pone el layout con las piezas de `plantillas`. Tres consecuencias
que importan:

1. **La cabecera de métricas no la escribe el modelo**: sale de los hallazgos, así
   que sus cifras son las de la base por construcción.
2. **El render va ANTES de validar**: lo que `validar_cifras` revisa es el texto
   que va a leer el usuario, cabecera incluida.
3. **Tres formas de fallar, una sola puerta**: JSON truncado
   (`finish_reason: length`), JSON que no parsea, y `informe_render` devolviendo
   NULL terminan todas en el mismo `invalido` → reintento → informe seco. El seco
   pasa por el **mismo** render, así que pierde la narración pero no el formato.

`Extraer` marca `truncado` con `finish_reason === 'length'`: sin eso se entregaba
media narración como si estuviera completa (fue el bug del "informe cortado", con
`tokens_salida == max_tokens`). Ojo con el cupo: `deepseek-v4-flash` razona y los
`reasoning_tokens` cuentan dentro de `completion_tokens` —una corrida de 1.131
caracteres gastó 3.897 tokens—, por eso `max_tokens` está en 8.000 (migración 028).

`RespFinal` parte por bloques (los `\n\n` que pone el render), después por línea y
en último caso a lo bruto. Ninguna etiqueta HTML del informe abarca más de una
línea —los `<b>` van en títulos y métricas, el cuerpo de cada viñeta va sin
marcar—, así que ningún corte puede dejar un `<b>` sin cerrar, que es lo que
Telegram rechaza con 400. El **último** mensaje usa `ejecucion.entregada`, que es
la fila que lleva el botón "🔄 Analizar otra vez": los botones tienen que quedar al
final del informe, no en la mitad.

### 6.4 wf_enviar — único punto de salida

`Inicio` → dos ramas:
- **Texto:** `Expandir` (una salida por respuesta) → `Resolver`
  (`resolver_plantilla`: texto + `reply_markup`) → `EsWa?` → `Filas` (aplana el
  teclado y cuenta) → `CuantasFilas` (Switch) → `EnviarTexto0…EnviarTexto6`.
- **Documento:** `HayDoc?` → `PrepDoc` → `EnviarDoc` (Telegram sendDocument con el binario).

> **Por qué hay siete nodos de envío en vez de uno.** El nodo de Telegram de n8n
> no acepta un `reply_markup` ya armado: `getNodeParameter` resuelve los parámetros
> contra la **descripción** del nodo y descarta todo lo que no esté declarado ahí.
> Resultado: la *forma* del teclado (cuántas filas, cuántos botones) tiene que
> estar literal en el workflow, y solo las hojas —el texto del botón y su
> `callback_data`— pueden salir de una expresión.
>
> Comprobado con cinco sondas contra la API real, mirando si Telegram devuelve
> `reply_markup` en la respuesta:
>
> | Sonda | Qué se probó | Resultado |
> |---|---|---|
> | A | `additionalFields.reply_markup` (objeto y string) | se descarta |
> | B | `inlineKeyboard` entero por expresión | teclado vacío |
> | E | el array `buttons` de la fila por expresión | llegan los botones pero **sin** `callback_data`: *"Text buttons are unallowed in the inline keyboard"* |
> | F | el objeto `row` por expresión | teclado vacío |
> | D | forma literal + expresiones en las hojas | **funciona** |
>
> De ahí el diseño: un nodo por cantidad de filas y `teclado_markup` aplanando a
> un botón por fila con el tope de `MAX_FILAS`. El tope está en los **dos** lados
> (generador y base) para que no pueda existir un teclado que el enviador recorte
> en silencio.
>
> La alternativa limpia es un nodo HTTP Request contra `api.telegram.org`, con
> control total del body y sin tope de filas. Requiere dos cosas: que
> `TELEGRAM_BOT_TOKEN` esté en el entorno del contenedor de n8n —hoy solo lo ve el
> servicio `registrador`, y agregarlo obliga a **recrear** el contenedor— y que el
> acceso a variables de entorno desde los nodos esté habilitado
> (`N8N_BLOCK_ENV_ACCESS_IN_NODE`, hoy sin definir; verificar antes de contar con
> ello). El token no puede ir por credencial: la de Telegram no tiene bloque
> `authenticate` y la API solo acepta el token en la ruta de la URL. Pendiente de
> decisión.

`EnviarTexto*` va **sin `onError`** a propósito: un mensaje que no llega es un
fallo real y tiene que verse. Con `continueRegularOutput` la ejecución quedaba
marcada como exitosa, no se guardaba nada
(`EXECUTIONS_DATA_SAVE_ON_SUCCESS=none`) y el informe simplemente no aparecía en
el chat sin dejar rastro en ningún lado. `retryOnFail` (3 intentos) cubre el hipo
transitorio.

### 6.5 wf_cron — resiliencia programada y proactividad

`Cada5min` → `Mantenimiento` (`mantenimiento_ciclo`) → dos ramas de reparto:

- `Fanout` (una salida por notificación) → `Avisar` (wf_enviar) — reaper,
  recordatorios y **alertas** (§5.8).
- `FanoutEjec` (una salida por ejecución) → `Analizar` (wf_ejecutar) — el
  **informe periódico** (§5.8).

Los dos nodos de la segunda rama son los únicos que agregó la Fase E: solo
reparten lo que Postgres ya decidió. Ver §7.

### 6.6 wf_error — error workflow de los otros

`Error Trigger` → `Clasificar` (regex sobre el mensaje decide `transitoria`:
timeout/429/ECONNRESET…) → `Registrar` (INSERT en `fallas`) → `Admins` (arma
notificación con el detalle técnico) → `FanoutAdmin` → `AvisarAdmin` (wf_enviar).
El usuario final nunca ve el stack trace.

> **wf_admin no existe como workflow.** Con un solo bot hay un solo webhook. Los
> comandos de operación viven en `router_procesar_mensaje` restringidos por
> `usuarios.rol` — "cero código nuevo", exactamente como pide el plan.

### 6.7 wf_wa_router — el segundo canal

WhatsApp entra por la Cloud API de Meta y usa **el mismo cerebro**: no hay una
segunda máquina de estados.

- `WebhookGet` → `Verificar` → `TokenOk?` → `Challenge` / `Rechazar`: el
  *handshake* de suscripción de Meta, que es un GET con un token que se devuelve
  tal cual.
- `Webhook` (POST) → `Normalizar` (arma el mismo evento que Telegram, con
  `canal: 'whatsapp'`) → `Router` (`router_procesar_mensaje`) → `Despachar` →
  `Switch` → wf_enviar / wf_ingesta / wf_ejecutar. Idéntico a §6.1.

La identidad se cuelga en `identidades` (canal + `wa_id`), el `chat_id` que viaja
por los sobres es el teléfono en dígitos, y `wf_enviar` decide al final por qué
canal contestar (`canal_de_chat`, `044`).

Las diferencias de interfaz las absorbe la salida, no el router: máximo 3
botones (más de eso va como lista desplegable), `*negrita*` en vez de HTML
(`wa_texto`), y cuerpo de 1024 caracteres cuando lleva botones (`wa_payload`).

> **La ventana de 24 h de Meta.** Solo se puede iniciar conversación dentro de
> las 24 h del último mensaje del usuario; fuera de eso hacen falta *message
> templates* aprobadas. Consecuencia: **los recordatorios del cron y las alertas
> no salen por WhatsApp** para quien tenga esa única identidad. El flujo normal
> no se ve afectado, porque el bot siempre responde a algo recién enviado.

Meta no manda cabecera secreta como Telegram: hoy la defensa es la ruta con
sufijo aleatorio (`WA_WEBHOOK_PATH`) más el filtro por `phone_number_id`;
verificar `X-Hub-Signature-256` sigue pendiente. Alta y credenciales, en
`docs/WHATSAPP.md`.

---

## 7. Estados de falla y resiliencia

| Caso | Manejo |
|---|---|
| **Archivo que no parsea** | `estado='error'` solo en ese `documento`; la sesión sigue viva. El usuario recibe "procesé N de M, revisa X". Nunca se aborta el lote. |
| **Ejecución colgada** | Si el LLM se cae o n8n se reinicia, la fila queda `procesando`. `mantenimiento_ciclo` (cada 5 min) marca `fallida` las ejecuciones con `inicio < now()-15min`, libera la sesión y avisa al usuario. |
| **Sesión abandonada** | Sesiones `intake/recibiendo` con `ultima_actividad < now()-24h` → `expirada` + recordatorio único. También da la métrica de dónde se abandona. |
| **Falla de workflow** | wf_error registra en `fallas`, clasifica transitoria y avisa al admin con el detalle. |
| **Cifra inventada por el LLM** | `validar_cifras` la detecta; la ejecución reintenta una vez y, si vuelve a fallar, envía el **informe seco** sin narración. Mejor un informe seco que uno con cifras falsas. |
| **Cupo superado** | `ejecucion_preparar` devuelve `{bloqueado:true}` antes de gastar tokens; el usuario recibe el mensaje del límite. |
| **Falla el snapshot o el registro de recomendaciones** | `ejecucion_cerrar` los envuelve: la falla queda en `fallas` y la ejecución se cierra igual. Un informe entregado vale más que una foto perfecta, y una falla no arrastra a la otra. |
| **Falla la evaluación de alertas** | El reaper ya corrió antes: sus notificaciones salen igual. Lo que no puede dejar de correr no depende de lo que sí. |

---

## 8. Control de costo

`v_consumo_negocio` agrega tokens y costo del mes por negocio. `ejecucion_preparar`
lo consulta antes de devolver el prompt. `negocios.cupo_tokens_mes = 0` bloquea.
El costo se estima con `parametro('costo_por_1k_tokens_usd')`. Cada ejecución
guarda `tokens_prompt`, `tokens_salida` y `costo` — auditoría real, no estimada.

Modelo: **`deepseek-v4-flash`** (barato, razona). Para mejor redacción,
`deepseek-v4-pro` — es un `UPDATE prompts SET modelo=…`, no tocar n8n.
(`deepseek-chat` ya no existe.)

---

## 9. Vistas

**`mov_visibles`** (053) — la fuente de lectura de todo lo que analiza:
`movimientos` filtrada por `plan_desde(negocio_id)`. Las filas sin fecha nunca
se ocultan.

> **La regla, en una línea: lo que CALCULA lee `mov_visibles`; lo que ESCRIBE o
> CORRIGE lee `movimientos`.** Si el matching o `cartera_refacturar` miraran por
> la ventana del plan, confirmar un alias dejaría de arreglar los movimientos
> viejos y la re-facturación saltaría facturas en silencio. Las RPC del portal
> también leen la tabla: el portal muestra lo que el usuario cargó, que es
> justamente el argumento para que amplíe el plan.

**Los tres orígenes del stock** (054, `v_balance_unidades.origen_stock`):

| Valor | Significado |
|---|---|
| `conteo` | Hay un conteo y no hubo movimientos después. Stock contado. |
| `calculado` | Último conteo + comprado − vendido desde esa fecha. |
| `estimado` | No hay conteo: comprado − vendido. Es el comportamiento histórico, conservado, pero **marcado**. |

Lo derivado de un stock `estimado` lo dice: las reglas "se agota" y "plata
quieta" lo aclaran en su texto, la nota de Inventario del índice de salud lleva
un asterisco con su nota al pie, y `recomendaciones_negocio` publica
`origen_stock` en cada elemento.

**Cálculo** (la aritmética vive aquí, no en plpgsql; todas leen `mov_visibles`):
`v_costo_actual_producto`, `v_precio_actual_producto`, `v_margen_producto`,
`v_deriva_costo`, `v_rotacion_producto` (incluye días de cobertura),
`v_balance_unidades`, `v_pareto_utilidad`.

**Comparación y decisión** (las que consumen las fases B–F):
`v_proveedor_mas_barato` (el más barato **conocido**, de sus propias compras),
`v_cartera_tercero` (saldo por deudor; la regla separa vencido de por vencer),
`v_perfil_negocio` (lo estable del negocio, §4.4).

**Elegibilidad de la proactividad** — dos vistas que existen para decir *que no*:
`v_negocios_alertables` (hay a quién avisarle, autorizó, y entraron datos después
del último análisis) y `v_negocios_informe_periodico` (ya vio un informe, pasaron
30 días, cargó datos desde entonces).

**Operación** (la observabilidad también son SELECTs):
`v_consumo_negocio`, `v_sesiones_atascadas`, `v_embudo_servicios`
(dónde se cae la gente), `v_ejecuciones_fallidas`, `v_calidad_matching`,
`v_salud_ingesta`.

`v_embudo_servicios` es la más útil en validación con clientes: dice en qué paso
exacto abandonan, que es la única forma de saber si el problema es el servicio o
la conversación.

---

## 10. Operación

### Migraciones
`bin/migrar.sh` aplica `db/migraciones/*.sql` en orden, cada una en su
transacción, registrando el archivo en `schema_migraciones`. Idempotente:
re-ejecutar no repite las ya aplicadas. Para una migración nueva, crear
`db/migraciones/NNN_nombre.sql` y correr el script.

### Perfil del bot en Telegram
`bin/configurar-bot.sh` deja puestos la descripción larga y corta (la pantalla
"¿Qué puede hacer este bot?"), el menú de comandos —ámbito de defecto con los
comandos de usuario, y un ámbito por chat de admin que agrega los de operación,
sacando los chats de `usuarios.rol`— y el botón de menú. Es idempotente; se
corre a mano cuando cambian los textos o aparece un admin nuevo. El
`registrador` ya no toca el menú: lo hacía en cada reconexión del túnel y
pisaba la separación por ámbito.

### Roles del portal
`bin/preparar-portal.sh` crea `authenticator`, `portal_anon` y `portal_usuario`.
Corre como **superusuario** —`CREATE ROLE` no está al alcance del dueño de la
base— y por eso no puede ser una migración. Es idempotente: se vuelve a correr
para rotar la contraseña. Orden en una instalación nueva:

```bash
bash bin/preparar-portal.sh      # roles
bash bin/migrar.sh               # el resto, incluida la 033 (que da los GRANT)
docker compose up -d
```

Toda migración que agregue una RPC `portal_*` termina en
`NOTIFY pgrst, 'reload schema'`, o PostgREST no ve la firma nueva. Ver §5.10.

### Extensiones
`db/init/00_bases.sh` crea las dos bases y sus roles, e instala `pgcrypto`
(hash), `pg_trgm` + `unaccent` (matching). Corre una sola vez, al primer arranque
del volumen.

### Respaldo
`bin/respaldo.sh` — `pg_dump --format=custom` de ambas bases, retención 14 días.
La base ES la herramienta entera. Restaurar:
`pg_restore --clean --if-exists -U <usuario> -d <base> <archivo>`.
Recomendado además WAL archiving en producción.

### Workflows en git
`bin/exportar-workflows.sh` exporta los 7 a `workflows/` (formato separado).
No por portabilidad: reconstruirlos a mano tras perder un volumen es un día
perdido. Las credenciales NO se exportan ahí (van cifradas con
`N8N_ENCRYPTION_KEY`); se recuperan restaurando el dump de la base `n8n` con esa
misma clave.

### Bancos de prueba
`bash bin/pruebas.sh` corre los bancos de `db/pruebas/` y resume el resultado
(`-v` para la salida completa; se le pueden pasar nombres sueltos). **Todos
corren dentro de una transacción que termina en ROLLBACK**: no dejan rastro y se
pueden correr contra producción.

| Banco | Qué comprueba |
|---|---|
| `aceptacion.sql` | Las pruebas de aceptación del roadmap, automatizadas. |
| `router_casos.sql` | 67 casos que recorren los cinco estados de la conversación, los reportes de admin y la entrada por WhatsApp. **Correrlo antes y después** de tocar el router y comparar: es lo que hizo verificable la A4. No lleva golden a propósito — tres de sus casos (`/salud`, `/matching`, `/pendientes`) reportan la base entera y su salida cambia con cada dataset. |
| `reglas_comparativas.sql` | Un negocio sintético de 15 meses donde cada producto dispara una sola de las cuatro reglas de B3. Anclado a `current_date`, así que no caduca. |
| `empty_state.sql` | El negocio recién nacido —cero de todo— : que exista, que opere y que **no invente nada**. Los demás bancos parten de un negocio con historia. |
| `escenarios_generados.sql` | Que Chasqui vea en los datos cargados **exactamente** lo que declara el manifest del generador. |

### Datos de prueba sintéticos
Para ejercitar muchos negocios y escenarios sin datos privados de clientes, hay
un generador en cuatro piezas (`bin/gen_datos_prueba.py` escribe CSV de ventas y
facturas UBL 2.1; `bin/cargar_datos_prueba.py` los mete **por la ruta real de
ingesta**; `bin/validar_datos_prueba.py` calcula un oráculo independiente;
`db/pruebas/escenarios_generados.sql` compara). El dataset se adapta a Chasqui y
nunca al revés: lo que no se puede representar por las rutas que existen queda
declarado como limitación. Manual completo en `docs/TEST_DATA_GENERATOR.md`, el
diseño en `docs/PLAN_DATOS_PRUEBA.md`.

`bin/prueba_ciclo_vida.py` es el complemento de `empty_state`: prueba que un
negocio vacío pueda **moverse** a operando —primera factura, primer CSV,
`/listo`, análisis— por las rutas que usa un usuario real y en ese orden.

### Prueba headless del motor
```bash
docker compose exec postgres psql -U chasqui -d chasqui -c \
  "INSERT INTO ejecuciones (negocio_id,servicio_codigo,estado) VALUES (1,'ventas_compras','preparando');"
docker compose exec -e N8N_RUNNERS_BROKER_PORT=5699 n8n n8n execute --id wfEjecutar000000001
```
El `N8N_RUNNERS_BROKER_PORT=5699` evita el choque con el broker del contenedor en 5679.

---

## 11. Cómo agregar un servicio (sin tocar n8n)

```sql
-- 1. el servicio. `modulo_codigo` decide bajo qué botón del menú aparece;
--    `entrada` distingue los que piden archivos de los que se disparan
--    escribiendo. (`pasos` se dio de baja en la 057: el router los resuelve.)
INSERT INTO servicios (codigo, nombre, descripcion, entrada, funcion_hallazgos,
                       modulo_codigo, orden)
VALUES ('consumo_publicos', 'Consumo de servicios públicos', '…', 'archivos',
        'hallazgos_generar', 'negocio', 20);

-- 2. qué archivos pide
INSERT INTO servicios_entradas (servicio_codigo, formato_codigo, obligatorio, min_archivos, max_archivos)
VALUES ('consumo_publicos', 'recibo_csv', true, 1, 12);

-- 3. un formato nuevo, si aplica. Para tabulares normalmente NO hace falta:
--    el sistema aprende el layout solo la primera vez que lo ve. Se escribe a
--    mano cuando querés fijar el mapeo sin pasar por el LLM.
INSERT INTO formatos_documento (codigo, nombre, mime_patrones, extensiones,
                                funcion_parseo, mapeo, clase, huella)
VALUES ('recibo_csv', 'Recibos POS', '{text/csv}', '{csv}', 'ingesta_cargar_tabular',
        '{"columnas":{"fecha":"fecha","valor_total":"valor"},"tipo":"compra",
          "decimal":".","miles":"","formato_fecha":"YYYY-MM-DD"}',
        'tabular', ingesta_huella(ARRAY['fecha','valor']));

-- 4. el prompt del LLM
INSERT INTO prompts (servicio_codigo, sistema, usuario, modelo)
VALUES ('consumo_publicos', '…', '… {{hallazgos}}', 'deepseek-v4-flash');

-- 5. si el servicio tiene reglas propias, qué mide cada una (opcional, 066)
--    `metrica` sale de una lista cerrada por CHECK; una magnitud nueva sí
--    obliga a tocar la tabla.
INSERT INTO metricas_resultado (regla, metrica, direccion, umbral_pct)
VALUES ('consumo_alto', 'costo', 'baja_mejor', 5);
```

**El botón del servicio aparece solo**: `teclado_modulo()` lee los servicios
activos de ese módulo (y `teclado_intake()`, el de `/nueva`), así que los
menús se arman en el momento. No hay nada que tocar en n8n… con un límite: el
teclado tope 6 botones (`parametros.teclado_max_filas`), o sea **4 servicios por
módulo** (los otros dos los gastan "Cómo funciona" y "Volver"), o 5 en el menú
de `/nueva`, donde el sexto es Cancelar. Un módulo nuevo compra 4 más. Pasado eso hay
que subir el tope en los dos lados (`MAX_FILAS` en `bin/gen_wf_enviar.py` y el
parámetro) y regenerar wf_enviar, o paginar el menú. Es la única cosa de la
conversación que no se resuelve con un INSERT, y la razón está en §6.4.

Ojo también con el prompt: pedir estructura JSON es parte del contrato con
`informe_render`. Un prompt nuevo tiene que devolver el mismo esquema
(`titular` más `hallazgos[]` o `secciones[]`, y `acciones[]`) o el render
devuelve NULL y el informe sale seco siempre.

Si el servicio necesita un cálculo nuevo, se agregan vistas y se extiende
`hallazgos_generar`. **Si obliga a abrir un workflow, el diseño está mal y se
corrige ahí, no después.**

---

## 12. Seguridad

- Postgres expuesto solo en loopback (`127.0.0.1:5432`).
- Webhook de Telegram verificado por secreto de cabecera (wf_router lo rechaza si no coincide).
- Credenciales de n8n cifradas con `N8N_ENCRYPTION_KEY`; `.env` fuera de git.
- Nodos Code no leen variables de entorno (`N8N_BLOCK_ENV_ACCESS_IN_NODE=true` por defecto en 2.0): los secretos van por credenciales.
- `retryOnFail` solo en nodos idempotentes (el registro por hash lo es; un envío de Telegram no).
- Autorización de datos explícita del usuario antes de tratar nada (`autorizacion_datos`).
- El editor de n8n **no** queda expuesto: el túnel apunta al proxy, que solo pasa
  `/webhook`, `/api` y `/portal`.
- Portal sin contraseñas: enlace de un solo uso (se guarda el hash, vence a los
  15 min) → JWT firmado en Postgres. `portal_anon` solo puede abrir sesión;
  `portal_usuario` solo las RPC `portal_*`, y cada una deriva el negocio de la
  sesión, nunca de un parámetro. Ninguna función es pública por defecto (§5.10).
- Al LLM solo le llegan cifras ya calculadas y, en la ingesta, nombres de
  columnas con cinco filas de muestra. Nunca el archivo completo.

---

## 13. Troubleshooting

| Síntoma | Causa probable | Acción |
|---|---|---|
| El bot no responde | Webhook desapuntado tras reinicio del túnel | Ver logs de `registrador`; debe re-registrar solo. Verificar `getWebhookInfo`. |
| El bot no responde y el webhook está bien | wf_router regenerado **sin** el `.env` cargado: el secreto quedó en `''` y `Normalizar` descarta todo update sin dejar error. Se ve como una ejecución exitosa donde solo corrieron `Webhook` y `Normalizar`, con `items: []` | `set -a; . ./.env; set +a` y regenerar. El generador ahora aborta si falta. |
| Los mensajes llegan sin botones | El teclado se perdió en el nodo de Telegram | Confirmar en la respuesta de la API que viene `reply_markup`. Si falta, la forma del teclado no es literal en el nodo: ver §6.4. |
| Un botón deja el relojito girando | `Responder` falló (callback vencido) o el update no trae `callback_query.id` | Cosmético; el mensaje se procesa igual. |
| Botón que no hace nada | `callback_data` recortado a 64 caracteres, o el estado ya no acepta esa acción | `SELECT teclado_markup(teclado) FROM plantillas WHERE clave='…'` y comparar con lo que espera el router. |
| "column … does not exist" en un nodo Postgres | Texto embebido con comillas dobles (identificador) en vez de literal | Usar `'…'` con `.replaceAll("'","''")`, no `JSON.stringify`. |
| PDF vacío / "invalid base64" | Modo binario filesystem: `$binary.data.data` no trae el base64 | Leer el buffer con `getBinaryDataBuffer` (ver `PdfB64`). |
| `n8n execute` falla con "port 5679 in use" | Choca con el broker del contenedor | Pasar `N8N_RUNNERS_BROKER_PORT=5699`. |
| Informe sale seco (sin narración) | `validar_cifras` rechazó el texto dos veces | Revisar el prompt; el modelo está inventando o formateando cifras fuera de los hallazgos. |
| Ejecución atascada en `procesando` | LLM caído o n8n reiniciado | El reaper la barre en ≤5 min; ver `v_sesiones_atascadas`. |
| Credenciales "no se pueden descifrar" tras mover el stack | `N8N_ENCRYPTION_KEY` distinta | Restaurar la clave original del `.env`. |
| El portal responde 404 en una RPC recién creada | PostgREST tiene la caché de esquema vieja | La migración tiene que terminar en `NOTIFY pgrst, 'reload schema'`; si no, `docker compose restart postgrest`. |
| El portal responde 401/403 con un enlace recién pedido | El token ya se usó, venció (15 min), o `PORTAL_JWT_SECRET` no coincide entre PostgREST y `app.settings.jwt_secret` | Pedir otro con `/portal`; verificar que las dos variables del compose salgan del mismo valor. |
| `/portal` contesta "todavía no tengo configurada la dirección" | Falta el parámetro `portal_url_base` | `UPDATE parametros SET valor = '"https://…"'::jsonb WHERE clave='portal_url_base' AND negocio_id IS NULL;` |
| No llega ninguna alerta pese a haber problemas altos | Alguna de las cinco compuertas de §5.8 | `SELECT * FROM v_negocios_alertables;` y revisar `alertas_enviadas` (cooldown) y la hora contra `alerta_hora_desde/hasta`. |
| El informe periódico no dispara | Ya hay un análisis en curso, o el negocio nunca vio un informe | `SELECT * FROM v_negocios_informe_periodico;` |
| Una recomendación cerrada nunca se mide | No entraron datos **nuevos** desde el cierre (`creado_en`) | Es el comportamiento correcto: se reporta `sin_medir` hasta que llegue un archivo posterior. |
