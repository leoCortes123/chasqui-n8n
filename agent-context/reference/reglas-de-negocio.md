# Reglas de negocio implementadas

Toda regla se documenta por **la implementación**, no por su nombre. Umbrales
verificados contra la tabla `parametros` viva el 2026-08-19. Las fórmulas son
transcripción del SQL.

Convención de las 11 reglas de recomendación: todas viven en
`db/actual/funciones/recomendaciones_negocio.sql`, cada una como un CTE
`r_<regla>`, y todas emiten las mismas columnas:
`regla, clave_objeto, icono, titulo, impacto_mes, impacto_tipo, impacto_txt,
problema, opciones, origen_stock, datos`.

---

## Índice

| id | regla | tipo de impacto | umbral principal | dispara sobre |
|---|---|---|---|---|
| R1 | `costo` | mensual | `deriva_costo_alerta_pct` = 10 | producto |
| R2 | `proveedor` | mensual | 5 % fijo en código | producto |
| R3 | `margen` | mensual | `margen_minimo_pct` = 15 | producto |
| R4 | `agota` | **unico** | `dias_cobertura_min` = 7 | producto |
| R5 | `quieto` | **capital** | `rotacion_lenta_dias` = 60 | producto |
| R6 | `dependencia` | mensual (impacto 0) | `dependencia_proveedor_pct` = 50 | proveedor |
| R7 | `sin_ventas` | mensual | `dias_sin_venta_alerta` = 45 | producto |
| R8 | `proveedor_sube` | mensual | `subidas_proveedor_alerta` = 3 | producto |
| R9 | `margen_cae` | mensual | `caida_margen_pp_alerta` = 3 | producto |
| R10 | `vs_ano_anterior` | mensual | `caida_anual_pct_alerta` = 15 | negocio |
| R11 | `cartera` | **capital** | `cartera_mora_dias` = 15 | tercero |

---

## R1 · `costo` — el costo subió

```
Nombre        costo
Propósito     avisar que el costo de compra de un producto está por encima del
              de la primera compra registrada
Implementada  recomendaciones_negocio.sql, CTE r_costo (líneas ~100-145)
              vista v_deriva_costo
Entrada       v_deriva_costo (primer y último valor_unitario de compra por
              producto, ordenado por fecha), base.u_compradas, v_margen_producto
Proceso       impacto_mes = round((costo_fin - costo_ini) * u_compradas / meses)
              meses = greatest((max(fecha)-min(fecha))/30, 1)
Umbral        d.deriva_pct >= parametro('deriva_costo_alerta_pct')   [= 10]
Salida        problema: "El costo pasó de $X a $Y: subió Z% desde tu primera
              compra." (+ margen actual si hay precio)
              opciones: negociar; comprarle al más barato si existe y es menor;
              subir precio a costo/(1-margen_min) si el margen quedó bajo
              datos: {precio_sugerido} cuando aplica
Consumidores  informe (top 8), recomendaciones, alertas_evaluar
Limitaciones  "primera compra" es la primera VISIBLE: mov_visibles ya recortó
              por plan. Un negocio free ve derivas de 3 meses, no del histórico.
              No distingue unidad de compra de unidad de venta.
```

## R2 · `proveedor` — pagás más de lo que ya conseguiste

```
Nombre        proveedor
Propósito     detectar que el mismo producto se compró más barato a otro proveedor
Implementada  CTE alternativa + r_proveedor
Entrada       por_proveedor: precio promedio por (producto, raw->>'proveedor')
              alternativa: HAVING count(DISTINCT proveedor) > 1
Proceso       precio_pagado = sum(u*precio)/sum(u)   (promedio ponderado)
              precio_mejor  = min(precio_prom)
              impacto_mes   = round((precio_pagado - precio_mejor) * u_total / meses)
Umbral        precio_pagado > precio_mejor * 1.05    [5 % HARDCODEADO]
Salida        datos: {proveedor_sugerido, precio_mejor}
Consumidores  informe, recomendaciones, pedido_sugerido (vía v_proveedor_mas_barato)
Limitaciones  El 5 % NO es una fila de parametros: contradice CONTENIDO-001.
              El proveedor es texto libre de raw: dos grafías del mismo
              proveedor cuentan como proveedores distintos.
```

## R3 · `margen` — margen por debajo del mínimo

```
Nombre        margen
Propósito     productos que se venden con margen insuficiente
Implementada  CTE r_margen; vista v_margen_producto
Entrada       costo_actual (última compra), precio_actual (última venta),
              base.u_vendidas
Proceso       precio_objetivo = round(costo_actual / (1 - margen_min/100))
              impacto_mes = round(greatest(precio_objetivo - precio_actual, 0)
                                  * u_vendidas / meses)
Umbral        margen_pct < parametro('margen_minimo_pct')   [= 15]
              y precio_actual > 0 y costo_actual NOT NULL
Salida        datos: {precio_sugerido}  -> lo que consume el botón "Aplicar precio"
Consumidores  informe, recomendaciones, alertas_evaluar, recomendacion_accion
Limitaciones  CRÍTICA: no valida plausibilidad. Si el negocio compra por caja y
              vende por unidad, margen_pct sale absurdo (-1408 % medido) y la
              regla dispara con impactos de millones. Ver A-11.
              Es la regla que produjo las 57 alertas registradas hoy.
```

## R4 · `agota` — se agota, y cuánto comprar

```
Nombre        agota
Propósito     avisar antes de quedarse sin producto y decir cuánto pedir
Implementada  CTE r_agota; vistas v_rotacion_producto, v_balance_unidades
Entrada       unidades_por_dia, dias_cobertura, precio_actual, origen_stock
Proceso       impacto_mes = round(unidades_por_dia * dias_entrega * precio_actual)
              unidades_pedir = ceil(unidades_por_dia * (dias_entrega + dias_seguridad))
Umbrales      dias_cobertura < parametro('dias_cobertura_min')   [= 7]
              unidades_por_dia > 0
              dias_entrega_proveedor = 4 ; dias_stock_seguridad = 3
Salida        impacto_tipo 'unico' (lucro cesante de UN ciclo de entrega)
              datos: {unidades_pedir}  -> lo consume pedido_sugerido
              problema declara si el stock es estimado (DATOS-001)
Consumidores  informe, recomendaciones, pedido_sugerido/portal_pedido
Limitaciones  Cobertura negativa (vendió más de lo que registró comprando) se
              trata con un texto especial, no se descarta.
```

## R5 · `quieto` — plata inmovilizada

```
Nombre        quieto
Propósito     inventario que no rota
Implementada  CTE r_quieto
Entrada       dias_cobertura, balance, costo_actual, margen_pct, origen_stock
Proceso       impacto_mes = round(balance * costo_actual)
Umbrales      dias_cobertura > parametro('rotacion_lenta_dias')  [= 60]
              balance > 0
              icono y opciones cambian si margen_pct >= margen_alto_pct [= 35]
Salida        impacto_tipo 'capital'; declara origen del stock
Consumidores  informe, recomendaciones
Limitaciones  Depende de que exista al menos una venta del producto
              (v_rotacion_producto parte de ventas).
```

## R6 · `dependencia` — un solo proveedor concentra las compras

```
Nombre        dependencia
Propósito     riesgo de proveedor único
Implementada  CTE gasto_prov + r_dependencia
Proceso       pct = gasto_proveedor * 100 / gasto_total
Umbral        pct >= parametro('dependencia_proveedor_pct')   [= 50]
Salida        impacto_mes = 0, impacto_tipo 'mensual'
              PRIORIDAD FIJA 'media' y relevancia 0 (excepción explícita en el
              CTE priorizadas)
Consumidores  informe, recomendaciones
Limitaciones  Nunca puede ser prioridad alta, así que nunca genera alerta
              proactiva (alertas_evaluar sólo mira prioridad='alta').
```

## R7 · `sin_ventas` — dejó de venderse

```
Nombre        sin_ventas
Propósito     producto que tenía ritmo y se paró
Implementada  CTE venta_hist + r_sin_ventas
Entrada       por producto: primera venta, última venta, n_ventas, importe
Proceso       impacto_mes = round(importe / greatest((ultima-primera)/30, 1))
              -- su propio ritmo, no el del negocio
Umbrales      (v_hasta - ultima) > dias_sin_venta_alerta        [= 45]
              n_ventas >= ventas_minimas_historicas             [= 3]
              (ultima - primera) >= 14 días                     [HARDCODEADO]
Consumidores  informe, recomendaciones
Nota          "hoy" es v_hasta = max(fecha) de los movimientos, NO current_date.
              Comentario explícito: medir contra el reloj convertiría cada carga
              atrasada en una avalancha de alertas falsas.
```

## R8 · `proveedor_sube` — el proveedor viene subiendo

```
Nombre        proveedor_sube
Propósito     patrón de subidas repetidas del mismo proveedor (≠ R1, que es un
              salto que puede ser único)
Implementada  CTEs compras_serie -> compras_delta -> sube -> r_prov_sube
Entrada       compras del último año (fecha > v_hasta - 1 year) con proveedor,
              cantidad > 0 y valor_total > 0
Proceso       subidas = count(*) FILTER (precio > lag(precio) * 1.01)
                        particionado por (producto, proveedor) ordenado por fecha
              impacto_mes = round((precio_fin - precio_ini) * unidades
                                  / least(meses, 12))
Umbrales      subidas >= subidas_proveedor_alerta   [= 3]
              precio_fin > precio_ini
              margen del 1 % para no contar redondeos
Salida        DISTINCT ON (producto): se reporta el proveedor que más plata cuesta
              datos: {proveedor}
Consumidores  informe, recomendaciones
```

## R9 · `margen_cae` — el margen viene bajando

```
Nombre        margen_cae
Propósito     tendencia, no un mes malo
Implementada  CTEs snaps -> margen_hist -> r_margen_cae
Entrada       LOS DOS ÚLTIMOS SNAPSHOTS con metricas->>'parcial' distinto de true
              + v_margen_producto actual
Proceso       impacto_mes = round((h2.margen_pct - actual) / 100 * importe_ventas
                                  / meses)
Umbrales      actual < h1 < h2  (dos caídas seguidas)
              (h2 - actual) >= caida_margen_pp_alerta   [= 3 puntos porcentuales]
Salida        datos: {precio_sugerido} para volver al margen de h2
Consumidores  informe, recomendaciones
Limitaciones  ÚNICA regla que depende de snapshots. Con 0 snapshots (el estado
              actual de esta instalación) NUNCA dispara. Necesita al menos 3
              análisis completados en días distintos.
```

## R10 · `vs_ano_anterior` — vendés menos que el año pasado

```
Nombre        vs_ano_anterior
Propósito     comparación interanual del mes de referencia
Implementada  CTE anual + r_vs_ano
Entrada       ventas del mes de referencia y del mismo mes del año anterior
Proceso       mes_ref = último mes COMPLETO de datos:
                 si v_hasta es el último día de su mes -> ese mes
                 si no -> el mes anterior
              impacto_mes = round(antes - ahora)
Umbrales      antes > 0
              (antes - ahora) * 100 / antes >= caida_anual_pct_alerta   [= 15]
Salida        clave_objeto = 'negocio'
Consumidores  informe, recomendaciones
Limitaciones  Necesita 13 meses de historia VISIBLE. Con plan free
              (plan_free_meses_historia = 3) es inalcanzable: mov_visibles
              recorta a 3 meses. Sólo existe para planes de pago.
```

## R11 · `cartera` — te deben y ya se venció

```
Nombre        cartera
Propósito     señal de liquidez: plata tuya que no está
Implementada  CTE cartera_mora + r_cartera
Entrada       facturas tipo='venta' con saldo > 0, agrupadas por tercero
Proceso       saldo_vencido = sum(saldo) FILTER (vencimiento < current_date)
              impacto_mes  = round(saldo_vencido)   -- NO el saldo total
              dias_mora    = max(current_date - vencimiento)
Umbrales      dias_mora >= cartera_mora_dias   [= 15]
              saldo_vencido > 0
Salida        impacto_tipo 'capital'
              datos: {tercero_id, saldo_vencido, saldo_total, dias_mora}
Consumidores  informe, recomendaciones, portal_cartera
Limitaciones  Depende de facturas tipo='venta', que sólo existen si
              negocios.nit está lleno (cartera_facturar_dian). Con nit NULL
              -el caso de esta instalación- la regla es inalcanzable.
              Usa current_date, a diferencia de R7/R8/R10 que usan v_hasta.
```

---

## Reglas de priorización

```
Nombre        prioridad por tipo de impacto
Propósito     que un capital acumulado no le gane siempre a una fuga mensual
Implementada  CTE priorizadas
Entrada       impacto_mes, impacto_tipo, base_mes
Proceso       pct = impacto_mes * 100 / base_mes
              base_mes = greatest(sum(ventas), sum(compras)) / meses, mínimo 1
Umbrales      mensual : alta >= 2 %      media >= 0,5 %
              unico   : alta >= 10 %     media >= 3 %
              capital : alta >= 50 %     media >= 20 %
              (parametros prioridad_{alta,media}_{,unico_,capital_}pct)
Salida        prioridad + relevancia = pct / umbral_media_de_su_tipo
Consumidores  orden del informe, alertas_evaluar (sólo 'alta')
Limitaciones  'dependencia' está excluida por nombre, con prioridad fija 'media'.
```

```
Nombre        tope del informe
Implementada  CTEs visibles + salida
Proceso       rn <= 2 por regla; luego pos <= 8 global ordenado por
              (prioridad, relevancia DESC)
Consumidores  hallazgos_generar -> el modelo -> el informe
Limitaciones  Lo que queda fuera SÍ se persiste (p_registro=true), con
              en_informe=false, para no cerrarlo como resuelto por error.
```

---

## Reglas de ingesta

```
Nombre        compuerta de calidad de un archivo tabular
Implementada  ingesta_cargar_tabular_detalle
Proceso       pct_sin_fecha, pct_sin_valor sobre TODAS las filas, medidos ANTES
              de insertar
Umbral        max_pct_nulos = mapeo->>'max_pct_nulos', default 20 %
Salida        pasa -> INSERT masivo; no pasa -> estado 'error', 0 filas
              insertadas, motivo que nombra la columna y el formato
Consumidores  panel de carga
```

```
Nombre        descarte de archivo agregado
Implementada  ingesta_es_agregado + ingesta_cargar_tabular
Proceso       agregado = tiene valor Y NO tiene producto Y NO tiene cantidad
Salida        estado 'descartado' (no 'error'), motivo explícito, sin aviso
Consumidores  panel; el banco ingesta_sin_modelo lo verifica
Nota          Migración 075. Es la regla que impidió el doble conteo de
              $288 millones medido en la segunda prueba de usuario.
```

```
Nombre        escalera de identificación de layout
Implementada  ingesta_identificar_tabular
Proceso       huella conocida -> diccionario (44 patrones) -> modelo
Umbral        se llama al modelo SOLO si no se reconoce la fecha o ningún valor
Consumidores  wf_ingesta
```

```
Nombre        matching de producto
Implementada  match_resolver_producto
Proceso       código de barras -> alias exacto -> trigram -> pendiente
Umbral        similarity >= 0,45   (parametro 'match_umbral_trgm', QUE NO EXISTE
                                    como fila: el valor efectivo es el default)
Salida        auto-confirma y memoriza el alias con origen 'trigram'
Limitaciones  Crea producto sólo con código de barras. Sin código, nunca inventa.
```

```
Nombre        ventana de lectura por plan
Implementada  plan_desde() + vista mov_visibles + trigger movimientos_limite_plan
Proceso       plan <> 'free' -> NULL (sin límite)
              plan  = 'free' -> date_trunc('month', current_date)
                                - (plan_free_meses_historia - 1) meses  [= 3]
Salida        El trigger NO rechaza: incrementa documentos.filas_fuera_de_plan
              y deja pasar la fila. El filtro es de LECTURA.
Consumidores  todo el análisis (siempre lee mov_visibles)
Nota          CORE-002 cumplido y verificable.
```

---

## Reglas de proactividad

```
Nombre        R-A1 · alerta por hallazgo urgente
Implementada  alertas_evaluar(), llamada por mantenimiento_ciclo cada 5 min
Entrada       v_negocios_alertables (hay dato nuevo desde el último análisis
              completado, y el usuario autorizó datos y tiene chat)
Proceso       recomendaciones_negocio(negocio, true) -> filtra prioridad='alta'
              -> excluye las que tengan alerta dentro del cooldown
              -> ORDER BY impacto_mes DESC LIMIT alerta_max_por_corrida
Umbrales      alerta_cooldown_dias   = 14  (por regla + clave_objeto)
              alerta_hora_desde/hasta= 8 / 20 (zona America/Bogota)
              alerta_max_por_corrida = 1
Salida        INSERT alertas_enviadas + notificación con plantilla alerta.hallazgo
Consumidores  wf_cron -> wf_enviar
LIMITACIÓN    El tope es POR CORRIDA y la corrida ocurre cada 5 minutos. El
              cooldown es por (regla, clave_objeto), así que 65 productos con
              margen bajo son 65 alertas distintas esperando turno. Medido:
              57 filas en alertas_enviadas en una tarde, todas regla 'margen'.
              Los tres invariantes de ALERTAS-001 se cumplen y el resultado es
              exactamente el que la decisión quería evitar. Hallazgo A-10.
```

```
Nombre        R-A2 · informe periódico
Implementada  informes_periodicos_disparar()
Entrada       v_negocios_informe_periodico
Umbrales      informe_periodico_activo   = true
              informe_periodico_dias     = 30 desde el último análisis
              informe_periodico_min_movs = 10 movimientos nuevos
              franja horaria 8-20
              y ninguna ejecución en vuelo para ese negocio
Salida        aviso (informe.periodico_aviso) ANTES + ejecución nueva
```

```
Nombre        R-A3 · reaper y expiración
Implementada  mantenimiento_ciclo(), pasos 1 y 2
Umbrales      ejecución en preparando/procesando/validando con inicio < now()-15 min
                 -> fallida + sesión fallida + aviso ejecucion.fallida
              sesión intake/recibiendo con ultima_actividad < now()-24 h
                 -> expirada + aviso sesion.recordatorio
Nota          Es lo único de mantenimiento_ciclo que NO está envuelto en
              EXCEPTION: no puede dejar de correr.
```

---

## Reglas de plan y consumo

```
Nombre        bloqueo por cupo
Implementada  ejecucion_preparar
Entrada       v_consumo_negocio (tokens del mes en curso, date_trunc('month'))
Umbral        cupo_tokens_mes > 0 AND tokens_mes >= cupo    [default 2.000.000]
Salida        ejecuciones.estado='bloqueada', plantilla ejecucion.bloqueada_cupo,
              sin llamar al modelo
Nota          cupo = 0 se interpreta como "sin límite" aquí (la condición pide
              cupo > 0) pero router_plan lo muestra como "suspendido". Ambigüedad
              real: dos lecturas del mismo valor.
```

```
Nombre        avisos de consumo
Implementada  router_plan
Umbrales      pct >= 100 -> "superaste el cupo"
              pct >=  80 -> "vas por el X%"
              cupo =   0 -> "servicio suspendido"
Nota          parametros.costo_por_1k_tokens_usd = 0.0003 NO LO LEE NADIE:
              única aparición en todo el repo es la fila del baseline.
              Y ninguna función escribe ejecuciones.costo -el nodo Cerrar de
              wf_ejecutar sólo manda texto y tokens-, así que la columna queda
              en su DEFAULT 0 y v_consumo_negocio.costo_mes es siempre 0.
              El control de cupo funciona porque mide TOKENS, no pesos.
```

---

## Reglas de presentación

```
Nombre        iconos permitidos en el informe
Implementada  informe_render, array v_iconos_ok
Umbral        ⚠️ 📈 📉 📦 💰 🏆 🔎 🧾 🕐 ✅ ; cualquier otro se sustituye por 🔎
```

```
Nombre        tope de teclado
Implementada  teclado_markup (SQL) y MAX_FILAS en gen_wf_enviar.py
Umbral        parametros.teclado_max_filas = 6  ·  MAX_FILAS = 6
Limitación    El mismo número en dos sitios. Cambiar la fila sin regenerar el
              workflow produce teclados que el enviador no sabe expresar.
```

```
Nombre        troceado del informe
Implementada  gen_wf_ejecutar.py, nodo RespFinal (JavaScript)
Umbral        LIM = 3800 caracteres, HARDCODEADO
Proceso       corta por bloque (doble salto), luego por línea, luego a lo bruto;
              la plantilla de entrega se reserva para el ÚLTIMO trozo, para que
              los botones queden al final
Limitación    Es lógica de producto en un nodo. Contradice la tesis de AGENTS.md.
```
