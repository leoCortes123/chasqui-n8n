# Glosario de negocio

Cada término se define por **lo que hace el código**, no por lo que sugiere el
nombre. Entre paréntesis, dónde se comprueba.

---

**Negocio** — la unidad de aislamiento. Toda tabla de datos cuelga de
`negocios.id`. Se crea **solo** la primera vez que un usuario escribe al bot
(`usuario_de_canal`, migración 050); nadie lo registra a mano. Nombre por
defecto: `'Mi negocio'`.

**Usuario / identidad** — `usuarios` es la persona; `identidades` es su cuenta
en un canal (`UNIQUE(canal, id_externo)`). Un usuario puede tener identidad de
Telegram y de WhatsApp. `usuarios.telegram_*` es el modelo anterior, que sigue
poblado en paralelo.

**Sesión** — una conversación con un objetivo. Estados:
`intake` (eligiendo servicio) → `recibiendo` (llegando archivos) → `procesando`
(análisis en curso) → `completada` / `fallida` / `expirada`. Una sesión de
consulta nace directamente en `procesando` y muere con su ejecución
(`consulta_iniciar`).

**Servicio** — una fila de `servicios`. Declara `funcion_hallazgos` (qué SQL
produce el JSON de entrada al modelo) y `entrada` (`archivos` o `texto`). Hoy
hay 3: `ventas_compras`, `mercado_compras`, `consulta`.

**Módulo** — agrupador de servicios para el menú (`modulos`, 1 fila:
`negocio`). Con un solo módulo activo, `teclado_intake()` salta directo a él.

**Documento** — un archivo que mandó el usuario, guardado íntegro en
`documentos.contenido`. Identidad = `sha256` del contenido dentro del negocio.
Estados: `pendiente` → `parseado` | `error` | `descartado`.

**Descartado** — el archivo se entendió pero **el sistema decidió no cargarlo**
(migración 075). Único caso hoy: una tabla agregada (totales por día sin
producto ni cantidad), porque sumarla contaría dos veces lo que ya traen los
detalles (`ingesta_cargar_tabular`). No es un error del usuario y no dispara
aviso.

**Formato** — una fila de `formatos_documento`. `clase='documento'` lo parsea
Postgres solo (hoy sólo `dian_xml`); `clase='tabular'` necesita que n8n extraiga
las filas primero.

**Huella** — `md5` de las cabeceras de un archivo tabular, normalizadas,
deduplicadas y ordenadas alfabéticamente (`ingesta_huella`). Es la identidad de
un layout. Dos archivos del mismo POS comparten huella aunque cambien de orden
las columnas.

**Mapeo** — el `jsonb` de `formatos_documento.mapeo` que dice qué columna del
archivo es cada concepto canónico, más `tipo`, `decimal`, `miles`,
`formato_fecha` y `agregado`. Los conceptos canónicos son nueve, fijados por un
CHECK en `sinonimos_columna`: `fecha`, `producto`, `categoria`, `cantidad`,
`valor_unitario`, `valor_total`, `codigo`, `unidad`, `impuesto`.

**Agregado** — un archivo que trae valor pero **no** producto ni cantidad
(`ingesta_es_agregado`). Es un resumen, no un detalle.

**Movimiento** — una línea de compra o venta normalizada. `raw` guarda la fila
original. **Cuidado:** el proveedor no es una entidad aquí; es
`raw->>'proveedor'`, texto libre.

**Alias** — un texto de producto visto en un archivo, normalizado. Con
`producto_id` es un alias resuelto; sin él, un **pendiente** que espera que
alguien lo empareje en el portal.

**Matching** — resolver el texto de una línea a un `productos.id`. Cascada:
código de barras → alias exacto → trigram (`similarity ≥ 0,45`) → pendiente.
Nunca inventa un producto sin código de barras.

**Tercero** — proveedor o cliente identificado, sólo de facturas DIAN. Se
deduplica por NIT, o por `norm_texto(nombre)` si no hay NIT.

**Ejecución** — una corrida de análisis. Guarda los hallazgos que vio el modelo
y el texto entregado. Estados `estado_ejec`.

**Hallazgos** — el `jsonb` que `ejecucion_preparar` entrega al modelo. **Es todo
lo que el modelo ve del negocio.** Su forma depende del servicio.

**Salud** — seis notas de 0 a 100 (`ventas`, `margenes`, `inventario`,
`compras`, `riesgos`, `liquidez`) más el `indice` = promedio de las **no nulas**
(`salud_negocio`, `HALLAZGOS-001`). Una nota sin datos es `NULL` y no se rellena
con un valor neutro; si las seis son nulas, `salud_negocio` devuelve `NULL` y no
se dibuja semáforo.

**Recomendación** — un problema detectado por una de las **11 reglas**, con su
impacto en pesos y sus opciones, ya redactadas por SQL. Persiste después del
informe (`CORE-003`).

**Impacto** y **tipo de impacto** — `impacto_mes` es pesos; `impacto_tipo` dice
qué clase de pesos: `mensual` (fuga que se repite), `unico` (pérdida de una vez
si el evento ocurre), `capital` (plata que existe y está inmóvil). Cada tipo
tiene sus propios umbrales de prioridad, porque no son comparables.

**Relevancia** — `impacto_mes / base_mes` dividido por el umbral MEDIA **de su
propio tipo**. Es lo único comparable entre tipos y es lo que ordena dentro de
una prioridad.

**Base mes** — lo que mueve el negocio en un mes:
`greatest(ventas, compras) / meses`, mínimo 1. Denominador de toda prioridad.

**Detectado vs. mostrado** — `recomendaciones_negocio(negocio, true)` devuelve
**todo** lo detectado con `en_informe` marcado; en modo informe (`false`)
devuelve sólo el top: máximo **2 por regla** y **8 en total**. La distinción
existe para no cerrar como «resuelta» una recomendación que sólo quedó fuera del
top (migración 059).

**Snapshot** — foto diaria del negocio con márgenes y coberturas de **todos** los
productos, gasto por proveedor, precios por par (producto, proveedor), Pareto,
calidad del matching y los **umbrales con los que se midió**. Uno por día; el
segundo del día pisa al primero.

**Conocimiento** — hechos que el dueño escribe: precios, horarios, condiciones.
`/saber <texto>` en el chat o el portal. Se busca por trigram. **No** es memoria
conversacional: ver `../memory-and-state.md`.

**Pendiente de conocimiento** — una pregunta que Chasqui no supo responder, con
contador `veces`. Alimenta el portal para que el dueño la conteste.

**Plan** — `negocios.plan`. `free` limita **la lectura** a los últimos
`plan_free_meses_historia` meses (hoy 3) vía `plan_desde()` y `mov_visibles`.
Cualquier otro valor = sin límite. **Nunca borra nada** (`CORE-002`).

**Cupo** — `negocios.cupo_tokens_mes` (default 2.000.000). `ejecucion_preparar`
bloquea la ejecución si los tokens del mes lo superan. `cupo = 0` = suspendido.

**Origen del stock** — `conteo` (hay un conteo y no hubo movimientos después),
`calculado` (hay conteo y movimientos posteriores), `estimado` (nunca hubo
conteo: comprado menos vendido). Viaja hasta el texto que lee el usuario
(`DATOS-001`).

**Informe seco** — el informe generado **sin** el modelo, armando la estructura
desde los hallazgos (`informe_estructura_seca`) y renderizando con las mismas
plantillas. Es la degradación cuando el LLM falla dos veces o inventa cifras.

**Panel de carga** — **un** mensaje de Telegram que se edita en su lugar y se
fija, con el conteo de archivos y el botón Analizar. Tres modos: `panel`,
`esperando`, `analizando` (`carga_panel`).

**Cooldown de alerta** — `alerta_cooldown_dias` (14) por par
`(regla, clave_objeto)`. Ver la limitación real en `../business-rules.md` R-A1.
