# Interfaz con el LLM

## Respuesta corta a la pregunta clave

> **¿El LLM tiene acceso directo a datos numéricos, o sólo a resultados
> previamente calculados?**

`[CONFIRMADO]` **Sólo a resultados previamente calculados.** El modelo nunca ve
`movimientos`, ni una consulta SQL, ni una tabla. Recibe **un único JSON** que
Postgres armó, y ese JSON ya trae las cifras redondeadas, los porcentajes
calculados, los impactos en pesos y hasta las frases en español. Después,
`validar_cifras` audita el texto renderizado contra ese mismo JSON.

Matiz honesto `[INFERIDO]`: ese JSON **sí contiene números**, y muchos —22.175
bytes en el caso medido, con listas completas de productos, márgenes,
coberturas, derivas y Pareto. El modelo no puede *inventar* una cifra, pero
podría *elegir mal* cuál citar o atribuirla al producto equivocado, y
`validar_cifras` no lo detectaría porque el número sí estaba en el JSON.

---

## Modelos y endpoint

`[CONFIRMADO]`

| Qué | Valor | Dónde vive |
|---|---|---|
| Endpoint | `${DEEPSEEK_BASE_URL}/chat/completions` | `.env` → `bin/wf_lib.py:LLM_URL` → **horneado en el JSON al generar** |
| Valor actual | `https://generativelanguage.googleapis.com/v1beta/openai` | `.env` (proxy compatible con OpenAI) |
| Credencial | Header Auth `chasquiDs0000000001` («DeepSeek Header») | base de n8n, **no** en el repo |
| Modelo | `gemini-3.5-flash-lite` en los 4 registros activos | `prompts.modelo`, `prompts_tecnicos.modelo` |
| DEFAULT de la columna | `deepseek-v4-flash` | `db/base/000_esquema.sql` |

`[CONTRADICCIÓN]` El nombre del modelo es **entorno** guardado en filas de
**producto**. El DEFAULT de la columna apunta a un modelo que este proxy no
tiene: un prompt nuevo insertado sin `modelo` explícito nace roto. Registrado
como deuda `D-007`.

## Los tres puntos donde se llama al modelo

`[CONFIRMADO]` Sólo tres nodos HTTP en todo el sistema:

| Nodo | Workflow | Cuándo | Prompt |
|---|---|---|---|
| `InferirMapeo` | `wf_ingesta` | sólo si el diccionario no reconoció fecha ni valor | `prompts_tecnicos` clave `ingesta.inferir_mapeo` |
| `DeepSeek1` | `wf_ejecutar` | siempre que la ejecución no esté bloqueada | `prompts WHERE servicio_codigo = X AND activo` |
| `DeepSeek2` | `wf_ejecutar` | reintento único, mismo body | idem |

Todos con `retryOnFail`, `maxTries: 2`, `waitBetweenTries: 5000` (el comentario
del generador explica que los 429 de cuota piden ~17 s) y
`response_format: {type: "json_object"}`.

## Dónde viven los prompts

`[CONFIRMADO]` En dos tablas de contenido, **nunca en el código ni en n8n**:

| Tabla | Filas | Clave |
|---|---|---|
| `prompts` | 5 (3 activas) | por `servicio_codigo`, con `uq_prompt_activo` parcial: **un solo prompt activo por servicio** |
| `prompts_tecnicos` | 1 | por `clave` |

| id | servicio | v | modelo | temp | max_tokens | activo |
|---|---|---|---|---|---|---|
| 1 | ventas_compras | 5 | deepseek-v4-flash | 0.2 | 8000 | no |
| 2 | consulta | 1 | gemini-3.5-flash-lite | 0.1 | 3000 | **sí** |
| 3 | mercado_compras | 1 | deepseek-v4-flash | 0.2 | 8000 | no |
| 4 | ventas_compras | 6 | gemini-3.5-flash-lite | 0.2 | 8000 | **sí** |
| 5 | mercado_compras | 2 | gemini-3.5-flash-lite | 0.2 | 8000 | **sí** |

Sustitución de variables: `{{hallazgos}}` en `prompts.usuario`;
`{{columnas}}` y `{{muestra}}` en `prompts_tecnicos.usuario`. La hace un nodo
Code de n8n con `String.replace`.

## Qué recibe el modelo, por servicio

### `ventas_compras` — `hallazgos_generar(negocio)`

`[CONFIRMADO]` Claves del JSON:

```
negocio_id, generado_en, tipo_negocio,
umbrales     {margen_minimo_pct, deriva_costo_alerta_pct, dias_cobertura_min}
salud        {ventas, margenes, inventario, compras, riesgos, liquidez, indice,
              inventario_estimado}   -- o null
recomendaciones[]  <- top 8, YA priorizadas, con problema/impacto/opciones
                      REDACTADOS en español por SQL. Sin regla ni clave_objeto.
comparativo  {fecha_anterior, salud_anterior, salud_actual, salud_delta,
              ventas_anterior, compras_anterior}   -- o null si no hay snapshot
periodo      {desde, hasta, movimientos_venta, movimientos_compra}
resumen      {productos, con_precio, margen_promedio_pct}
margen_bajo[], deriva_costo[], baja_cobertura[], pareto[]
```

Tamaño medido en el negocio real: **22.175 bytes**.

### `mercado_compras` — `hallazgos_compras(negocio)`

`[CONFIRMADO]` `negocio_id, generado_en, periodo, resumen, gasto_producto[],
deriva_costo[], precio_disperso[], proveedores[], sin_venta[]`.
**No trae `recomendaciones`, ni `salud`, ni `encabezado`, ni `comparativo`.**

### `consulta` — `contexto_negocio_recuperar(negocio, contexto)`

`[CONFIRMADO]` `negocio_id, generado_en, pregunta, hechos[] (KB),
consulta {intencion, metrica, periodo, filtros, agregados, comparativo} | null,
negocio {tipo, periodo, productos, top_productos, proveedores, estacionalidad,
problemas_recurrentes, acciones, calidad}, estado (salud), comparativo,
recomendaciones (vigentes, 8), encabezado`.

## Qué NO recibe el modelo `[CONFIRMADO]`

- Ninguna fila de `movimientos`, `documentos`, `facturas`, `pagos`, `usuarios`,
  `identidades`, `sesiones`.
- Ningún identificador de persona: no hay `telegram_user_id`, `chat_id`, nombre
  de usuario ni NIT del negocio en los hallazgos.
- Ninguna clave interna de recomendación en modo informe (`regla`,
  `clave_objeto`, `datos`, `en_informe` sólo viajan con `p_registro = true`, que
  es el modo de `recomendaciones_registrar` y `alertas_evaluar`, no el del
  informe).
- El contenido de los archivos: en ingesta ve **nombres de columna y 5 filas de
  muestra**, nunca el archivo completo.
- `producto_id` sí aparece en `deriva_costo` y `baja_cobertura`
  `[CONFIRMADO]`; son ids internos sin valor externo.

## Formato de respuesta esperado

`[CONFIRMADO]` `response_format: json_object` en los tres nodos.

**Informe** (`ventas_compras`, `mercado_compras`):
```json
{ "titular": "≤100 chars",
  "hallazgos": [ {"icono","titulo","problema","impacto","opciones":[],"prioridad"} ],
  "acciones": ["…"] }
```
Topes que pide el prompt: 5 hallazgos, 3 opciones por hallazgo, 3 acciones.

**Consulta**:
```json
{ "titular": "≤200 chars",
  "secciones": [ {"icono","titulo","puntos":[]} ],
  "acciones": [] }
```

**Ingesta**:
```json
{ "tipo":"venta|compra", "decimal":".", "miles":",",
  "formato_fecha":"DD/MM/YYYY",
  "columnas": {"fecha":"…","producto":"…", …} }
```
o `{"error":"faltan columnas obligatorias"}`.

## Cómo se valida la respuesta

`[CONFIRMADO]` **Informe** — cuatro filtros en cadena:

1. `Extraer` (JS): marca `invalido` si `finish_reason='length'`, si el contenido
   no parsea como JSON, o si no es un objeto. Limpia un posible cerco ```` ```json ````.
2. `informe_render` (SQL): devuelve `NULL` si `titular` está vacío o la
   estructura no es un objeto. Filtra iconos contra lista blanca. Escapa HTML.
3. `validar_cifras` (SQL): compara el texto **ya renderizado** contra los
   hallazgos.
4. `Cifras1ok?`: exige `v.ok = true` **y** `invalido ≠ true` **y** texto no
   vacío.

`[CONFIRMADO]` **Ingesta** — `ingesta_registrar_formato_inferido` valida en SQL:

- si el JSON trae `error` → documento a `error`;
- si `columnas` no es objeto → `error`;
- **filtra a las 9 claves canónicas** y descarta cualquier valor que no sea un
  nombre de columna que exista de verdad en el archivo
  (`EXISTS (SELECT 1 FROM unnest(p_columnas) c WHERE c = val)`);
- exige `fecha` **y** (`valor_total` o `valor_unitario`); si no, `error` con
  motivo.

`[CONFIRMADO]` Es decir: **el modelo no puede hacer que se cargue una columna
que no existe**, y no puede hacer que se cargue un archivo sin fecha o sin valor.

## Qué ocurre si falla

| Fallo | Consecuencia |
|---|---|
| HTTP 429 / timeout / caída | `onError: continueRegularOutput` → `Extraer` no ve `choices` → `invalido` → reintento → informe seco |
| Respuesta truncada | igual |
| JSON no parseable | igual |
| Cifra inventada | igual |
| Dos intentos fallidos | `informe_estructura_seca` + `informe_render` → **informe seco**, `narrado = false` |
| Fallo en ingesta | `mapeo = {error: 'el modelo no devolvió un JSON válido'}` → documento a `error` con motivo |

`[CONFIRMADO]` El generador documenta por qué `continueRegularOutput` y no
`continueErrorOutput`: la salida de error estaba sin conectar y un 429 mataba la
ejecución en silencio.

`[CONFIRMADO]` El usuario **sí** se entera: `informe_render` añade el bloque
`informe.sin_narracion` («no pude verificar el texto del análisis, así que va la
lista seca») cuando renderiza una estructura seca.

`[CONFIRMADO]` Pero **la base no lo registra**: `wf_ejecutar` calcula `narrado`
y lo lleva hasta el item final, y `ejecucion_cerrar` no lo recibe ni existe
columna para él. Consultando `ejecuciones` no se puede saber cuántos informes
salieron secos, que es justo la métrica que diría si el modelo está fallando.

## Reparto código / IA, resumido

| Resultado | Quién lo produce |
|---|---|
| Toda cifra del informe | **SQL**, antes de llamar al modelo |
| Prioridad y orden | **SQL** |
| Textos base de cada recomendación | **SQL** (`format()` con `miles()`, `fmt_decimal()`) |
| Titular y reescritura | **IA** |
| Layout, cabecera, semáforo, bloque de datos base | **SQL** (`informe_render` + `plantillas`) |
| Mapeo de columnas de un layout nuevo | **SQL** primero; **IA** sólo si el diccionario falla |
| Cifras de cualquier archivo | **SQL**, siempre |
| Detección de intención de una pregunta | **SQL** (patrones en filas) |
| Agregados de una consulta | **SQL** (`intencion_agregados`) |

`[CONFIRMADO]` `CORE-001` se cumple en el camino auditado. La única frontera
delgada es la señalada arriba: el JSON de hallazgos es grande y el modelo puede
recombinar cifras legítimas.
