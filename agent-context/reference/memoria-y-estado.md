# Memoria y estado

«Memoria» no es un mecanismo en Chasqui: son **seis mecanismos distintos** con
alcances, vidas útiles y consumidores distintos. Este documento los separa.

---

## Los seis mecanismos

| # | Mecanismo | Tabla | Quién escribe | Quién lee | Vida |
|---|---|---|---|---|---|
| M1 | **Archivo original** | `documentos.contenido` (bytea) | `ingesta_registrar_documento` | nadie automáticamente; `portal_documentos` lista metadatos | permanente |
| M2 | **Datos normalizados** | `movimientos`, `productos`, `alias`, `terceros`, `facturas`, `conteos_inventario` | ingesta, matching, portal | todo el análisis vía `mov_visibles` | permanente |
| M3 | **Snapshot del negocio** | `snapshots_negocio` | `snapshot_tomar` desde `ejecucion_cerrar` | `snapshot_anterior`, `hallazgos_comparativo`, regla `margen_cae`, `portal_snapshots` | permanente, 1 por día |
| M4 | **Recomendaciones** | `recomendaciones` | `recomendaciones_registrar`, `recomendacion_accion` | informe, portal, `perfil_negocio`, `pedido_sugerido` | permanente |
| M5 | **Conocimiento** | `conocimiento`, `conocimiento_pendiente` | `/saber`, portal, botón «Aplicar precio» | `conocimiento_buscar` en toda consulta | permanente, con `vigente_desde`/`vigente_hasta` |
| M6 | **Estado de la conversación** | `sesiones` | router y carga | router | hasta cerrar; expira a las 24 h |

Y dos registros técnicos: `ejecuciones` (una fila por análisis, con los
hallazgos exactos y el texto entregado) y `alertas_enviadas` (cooldown).

---

## Qué se conserva, qué se elimina, qué se recalcula

`[CONFIRMADO]`

### Se conserva para siempre

Todo lo de M1–M5. **Ningún camino de código borra datos de negocio.** Las únicas
rutas de borrado del repositorio son herramientas de operación, fuera de
producción:

| Herramienta | Qué borra |
|---|---|
| `bin/limpiar_negocio.sh` | datos de prueba; conserva negocio, usuario e identidad, y todo el contenido del sistema. Con `--todo` borra también negocio y usuario |
| `db/limpiar_datos.sql` | idem, en SQL |
| `portal_conocimiento_borrar(p_id)` | **única función de producto que borra**: un hecho de la KB |
| `portal_cotizacion_revocar(p_id)` | no borra: cambia el estado |

`[CONFIRMADO]` `CORE-002` se cumple: bajar de plan no borra nada; sólo cambia lo
que `mov_visibles` deja ver. Un upgrade recupera el pasado sin volver a subir
nada, porque las filas nunca se fueron.

### Se elimina

| Qué | Cuándo | Dónde |
|---|---|---|
| Ejecuciones exitosas de n8n | **nunca se guardan** | `EXECUTIONS_DATA_SAVE_ON_SUCCESS=none` |
| Ejecuciones fallidas de n8n | a los 7 días | `EXECUTIONS_DATA_MAX_AGE=168` |
| Tokens del portal | se marcan usados; **la fila queda** | `portal_sesion_abrir` |
| `fallas` | **nunca**; no hay poda | — |
| `alertas_enviadas` | **nunca**; no hay poda | — |

### Se recalcula en cada lectura

`[CONFIRMADO]` **Todo el análisis.** No hay una sola tabla materializada, ni
cache de resultados, ni columna calculada persistida. `salud_negocio`,
`recomendaciones_negocio`, `v_margen_producto`, `v_rotacion_producto`,
`v_deriva_costo` y `v_pareto_utilidad` recorren `mov_visibles` desde cero cada
vez. Medido: 95,6 s para `hallazgos_generar` sobre 37.454 movimientos.

`[INFERIDO]` El snapshot **no** es una cache: no se lee para acelerar nada. Es
un registro histórico para poder comparar contra el pasado.

---

## Cómo se obtiene el contexto de una empresa

`[CONFIRMADO]` Depende del servicio. No hay un «contexto del negocio» único.

| Servicio | Función | Qué arma |
|---|---|---|
| `ventas_compras` | `hallazgos_generar(negocio)` | salud + 11 reglas + comparativo + periodo + resumen + 4 listas |
| `mercado_compras` | `hallazgos_compras(negocio)` | sólo compras; sin salud ni recomendaciones |
| `consulta` | `contexto_negocio_recuperar(negocio, {pregunta})` | KB + intención resuelta + `perfil_negocio` + salud + comparativo + recomendaciones vigentes |

`perfil_negocio(negocio)` (sobre `v_perfil_negocio`) es lo más parecido a un
«perfil»: tipo, periodo, productos, top productos, proveedores, estacionalidad,
problemas recurrentes, acciones, resultados de recomendaciones medidas,
histórico de salud y calidad del matching.

---

## ¿Existe snapshot del estado del negocio?

`[CONFIRMADO]` **Sí.** `snapshots_negocio`, uno por negocio y **día**
(`uq_snapshot_dia`, con `ON CONFLICT DO UPDATE`: el segundo análisis del mismo
día pisa al primero). Lo toma `snapshot_tomar` desde `ejecucion_cerrar`, sólo
para servicios con `entrada='archivos'` y ejecución `completada`.

Contenido de `metricas`:

```
totales           ventas, compras, movimientos_venta, movimientos_compra,
                  meses, base_mes
productos         total, con_precio, margen_promedio_pct
margenes[]        TODOS los productos (no sólo los que disparan regla)
coberturas[]      dias_cobertura, unidades_por_dia, balance, origen_stock
derivas[]         costo_ini, costo_fin, deriva_pct
proveedores[]     gasto y % (el % se congela; recalcularlo al leer mentiría)
precios_proveedor[]  par (producto, proveedor) -> precio promedio, unidades
ventas_producto[]    unidades e importe por producto
pareto[]
calidad           movs_sin_producto, dinero_sin_producto, pct_dinero_fuera,
                  productos_stock_estimado
umbrales          TODOS los parametros vigentes en ese momento
```

`[CONFIRMADO]` Tres decisiones de diseño explícitas y verificables:

1. Guarda **todos** los productos, no sólo los problemáticos. Guardar sólo los
   malos sería guardar el informe otra vez y no permitiría ver un deterioro.
2. Congela los **umbrales** con los que se midió. Una nota de salud que baja
   porque alguien cambió `margen_minimo_pct` no es un deterioro del negocio, y
   sin esto no habría forma de distinguirlo.
3. Devuelve `NULL` y **no inserta** si no hay un solo movimiento fechado: un
   snapshot de la nada haría creer que hubo un periodo medido donde todo valía
   cero.

`[CONFIRMADO]` `snapshot_version()` devuelve `1` — constante, nunca ha cambiado.
`snapshots_backfill()` existe para generar snapshots retroactivos parciales
(marcados con `metricas->>'parcial'`), y **no la llama nadie** (deuda D-006).

`[CONFIRMADO]` Estado real hoy: **0 snapshots**. Por tanto `hallazgos_comparativo`
devuelve `NULL`, el bloque comparativo no aparece en ningún informe, y la regla
`margen_cae` es inalcanzable.

---

## ¿Existe historial de recomendaciones?

`[CONFIRMADO]` **Sí, y es la memoria mejor construida del sistema.**

- `detectada_en` no se toca nunca al refrescar → «¿desde cuándo vengo así?».
- `revisada_en` se actualiza en cada corrida.
- `vista_en` y `veces_vista` sólo cuando entró al informe (top 8) → «te lo dije
  cuatro veces».
- `cerrada_en` + `cerrada_por` ∈ `{dato, accion_usuario, sin_datos}`.
- `datos.valor_al_cerrar` graba la magnitud **antes** de cerrar.
- `resultado` ∈ `{positivo, neutro, negativo}` lo pone `recomendaciones_medir`.

`[CONFIRMADO]` `recomendaciones_vigentes` expone `dias_abierta` y
`veces_vista`, y el prompt de consulta los describe como «lo que está pendiente,
desde cuándo y cuántas veces se lo dijiste».

`[CONFIRMADO]` Estado real hoy: **0 filas**.

---

## ¿Existe historial de decisiones ejecutadas?

`[CONFIRMADO]` **Parcial.** Lo que hay:

| Decisión del usuario | Dónde queda | Qué falta |
|---|---|---|
| «Ya lo hice» | `recomendaciones.cerrada_por='accion_usuario'`, `estado='resuelta'`, `cerrada_en` | no queda **quién** ni **qué hizo exactamente** |
| «No aplica» | `estado='ignorada'` | idem |
| «Aplicar precio» | una fila en `conocimiento` (`tipo='precio'`, `datos.recomendacion_id`) **con** `actualizado_por = usuario` | es lo único que registra autor |
| Pago registrado | `pagos.usuario_id`, `pagos.origen` | completo |
| Conteo de inventario | `conteos_inventario.origen`, `.documento_id` | **no guarda usuario** |

`[CONFIRMADO]` `recomendacion_accion` recibe `p_usuario_id` y **sólo lo usa**
para la rama `precio` (se lo pasa a `conocimiento_guardar`). Las ramas `hice` y
`no_aplica` lo descartan. No hay tabla de auditoría de acciones.

---

## ¿Existe memoria conversacional?

`[CONFIRMADO]` **No.** Con precisión:

- Ninguna llamada al LLM incluye turnos anteriores. `ArmarLLM` construye
  `messages: [system, user]` y nada más, en los tres puntos de llamada.
- `sesiones.contexto` guarda **una** pregunta (`{pregunta: "..."}`), y la sesión
  de consulta nace y muere en la misma ejecución (`consulta_iniciar` la crea en
  `procesando`; `ejecucion_cerrar` la cierra).
- No hay tabla de mensajes. Los mensajes del usuario **no se guardan** en
  ninguna parte: sólo el efecto que produjeron.
- Lo único que sobrevive de una pregunta es su registro en
  `conocimiento_pendiente` cuando no se pudo responder bien.

`[INFERIDO]` Consecuencia práctica: no se puede hacer «y del mes anterior?»
como segunda pregunta. Cada pregunta se resuelve sola. `intencion_resolver`
tiene que extraer producto, proveedor y periodo del texto de **esa** pregunta.

---

## Qué significa «conocimiento» dentro del sistema

`[CONFIRMADO]` Exactamente esto y nada más: **filas de la tabla `conocimiento`,
escritas por una persona**, con `tipo` libre (el sistema usa `faq` y `precio`),
título, contenido, `datos jsonb`, y vigencia por fechas. Se recuperan por
similitud trigram con la pregunta (`umbral 0,12`, máximo 8).

**No** es: embeddings (pgvector está congelado), no es RAG sobre documentos, no
es memoria del modelo, no es lo aprendido de los archivos.

`[CONFIRMADO]` `conocimiento_pendiente` es su complemento: la lista de lo que
**falta**. Se registra en dos casos: cuando no hay ni KB ni números, y cuando
hay números pero la KB no tenía nada. `veces` se incrementa por
`pregunta_norm`, así que la pregunta repetida sube en la lista del portal.

---

## Qué información está disponible durante una consulta

`[CONFIRMADO]` El JSON que `contexto_negocio_recuperar` arma. En orden de
autoridad según el propio prompt:

1. `consulta` — la cifra ya calculada, si alguna intención coincidió.
2. `hechos` — la KB. «Si la pregunta es por algo de acá, esto manda sobre todo
   lo demás».
3. `negocio` — el perfil agregado.
4. `estado` — las notas de salud de hoy.
5. `comparativo` — cómo estaba la vez pasada (`NULL` si no hay snapshot).
6. `recomendaciones` — las vigentes, con días abiertas y veces vistas.

`[CONFIRMADO]` **No** está disponible: el detalle de movimientos, los documentos,
la conversación previa, los datos de otro negocio.

---

## Aislamiento temporal: los dos «hoy»

`[CONFIRMADO]` Chasqui usa **dos** relojes distintos y conviene saber cuál:

| Reloj | Dónde | Por qué |
|---|---|---|
| `v_hasta` = `max(fecha)` de los movimientos | reglas R7 `sin_ventas`, R8 `proveedor_sube`, R10 `vs_ano_anterior`; `intencion_resolver` | un negocio que sube en agosto un archivo que termina en mayo no lleva tres meses sin vender: lleva tres meses sin cargar |
| `current_date` | R11 `cartera`, `plan_desde`, `conocimiento_buscar`, `v_cartera_edades` | el vencimiento de una factura y la ventana del plan son hechos del calendario |

`[INFERIDO]` La mezcla es correcta pero fácil de malinterpretar: dos reglas
vecinas en el mismo informe pueden estar hablando de fechas distintas.
