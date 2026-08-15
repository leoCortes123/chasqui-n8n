# Guía técnica — Chasqui n8n

Documento de referencia para quien opera, mantiene o extiende el sistema.

---

## 1. Tesis de diseño

n8n es un **runtime fijo de 6 workflows** que casi nunca se tocan. Todo el
comportamiento del sistema —los pasos de la conversación, los textos, los
umbrales, los prompts del LLM, las plantillas de PDF, los formatos de archivo
que se aceptan— **vive en filas de Postgres**, no en nodos de n8n.

La regla operativa que lo verifica: **si para lanzar un servicio nuevo hay que
abrir el editor de n8n, el diseño se rompió.** Agregar un servicio es un
conjunto de `INSERT`, no un cambio de workflow.

Corolario de reparto de responsabilidades:

- **Postgres hace** todo lo determinístico: parseo, normalización, matching,
  cálculo, máquina de estados de la conversación, decisiones.
- **n8n hace** solo lo que Postgres no puede: llamadas HTTP (LLM), render de
  PDF, descarga de archivos, reintentos con backoff. Nada de aritmética ni
  reglas de negocio en los nodos.

Motivo técnico, no estético: dentro de una transacción de Postgres una llamada
HTTP no tiene timeout controlable ni reintento, y un cliente lento mantendría
tomado el lock de la sesión bloqueando al usuario.

---

## 2. Stack y topología

```
Telegram  ──webhook──►  cloudflared (túnel)  ──►  n8n :5678
                                                    │
                            ┌───────────────────────┼─────────────┐
                            ▼                        ▼             ▼
                       Postgres :5432          Gotenberg :3000   DeepSeek API
                       ├── base "chasqui"      (render PDF)      (redacción)
                       │   (negocio: todo)
                       └── base "n8n"
                           (runtime n8n)
```

| Servicio | Imagen | Rol |
|---|---|---|
| `postgres` | postgres:16 | Dos bases separadas en una instancia: `chasqui` (negocio) y `n8n` (runtime). |
| `n8n` | n8nio/n8n:2.31.5 | Orquestador. Backend en la base `n8n` (no SQLite). |
| `gotenberg` | gotenberg/gotenberg:8 | HTML → PDF vía Chromium. Sin puertos publicados; solo la red interna. |
| `cloudflared` | cloudflare/cloudflared | Quick tunnel. Perfil `local`. |
| `registrador` | alpine:3.20 | Descubre la URL del túnel y re-registra el webhook de Telegram. Perfil `local`. |

**Migración a la nube:** apagar el perfil `local` (cloudflared + registrador) y
fijar `WEBHOOK_URL` al dominio real. Es la **única** variable que cambia. Ningún
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
`codigo (PK), nombre, descripcion, pasos jsonb, entrada, funcion_hallazgos,
modulo_codigo, orden, activo`
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

**`plantillas_pdf`** — `id, servicio_codigo, version, html, css, activo`. Un
activo por servicio.

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
| `teclado_servicios` | `() → jsonb` | un botón por servicio activo (`svc:<codigo>`) + Cancelar. Un servicio nuevo aparece solo en el menú. |
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
| `match_confirmar_alias(alias_id, producto_id) → void` | Confirmación manual; reaplica a los movimientos huérfanos que coincidan. |

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
| `admin_reporte(cmd) → text` | Formatea las vistas de operación como texto para Telegram (`/salud`, `/embudo`, `/fallas`, `/consumo`, `/matching`). |

**Botón y texto son el mismo camino.** Los `callback_data` de los teclados son
los propios comandos (`/nueva`, `/listo`, `/cancelar`, `acepto`), así que
`router_procesar_mensaje` no distingue un toque de un mensaje escrito: no hay dos
máquinas de estados que mantener sincronizadas. Los formatos propios son
`svc:<codigo>` (elegir servicio), `mod:<codigo>` (entrar a un módulo) y
`modayuda:<codigo>` (qué hace ese módulo) y `tipo:<codigo>` (naturaleza del
negocio).

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

## 6. Los 6 workflows

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
                            intake(elegir_servicio) con teclado_servicios()
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
Gotenberg y `plantillas_pdf` siguen en su lugar para poder volver atrás.

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

### 6.5 wf_cron — resiliencia programada

`Schedule (5 min)` → `Mantenimiento` (`mantenimiento_ciclo`) → `Fanout` (una
salida por notificación) → `Avisar` (wf_enviar). Ver §7.

### 6.6 wf_error — error workflow de los otros

`Error Trigger` → `Clasificar` (regex sobre el mensaje decide `transitoria`:
timeout/429/ECONNRESET…) → `Registrar` (INSERT en `fallas`) → `Admins` (arma
notificación con el detalle técnico) → `FanoutAdmin` → `AvisarAdmin` (wf_enviar).
El usuario final nunca ve el stack trace.

> **wf_admin no existe como workflow.** Con un solo bot hay un solo webhook. Los
> comandos de operación viven en `router_procesar_mensaje` restringidos por
> `usuarios.rol` — "cero código nuevo", exactamente como pide el plan.

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
`bin/exportar-workflows.sh` exporta los 6 a `workflows/` (formato separado).
No por portabilidad: reconstruirlos a mano tras perder un volumen es un día
perdido. Las credenciales NO se exportan ahí (van cifradas con
`N8N_ENCRYPTION_KEY`); se recuperan restaurando el dump de la base `n8n` con esa
misma clave.

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
-- 1. el servicio. `modulo_codigo` decide bajo qué botón del menú aparece.
INSERT INTO servicios (codigo, nombre, descripcion, pasos, modulo_codigo, orden)
VALUES ('consumo_publicos', 'Consumo de servicios públicos', '…', '[…]',
        'negocio', 20);

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

-- 5. la plantilla PDF (opcional: hoy el informe se entrega como texto)
INSERT INTO plantillas_pdf (servicio_codigo, html, css) VALUES ('consumo_publicos', '…', '…');
```

**El botón del servicio aparece solo**: `teclado_modulo()` lee los servicios
activos de ese módulo (y `teclado_servicios()`, los de `/nueva`), así que los
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
