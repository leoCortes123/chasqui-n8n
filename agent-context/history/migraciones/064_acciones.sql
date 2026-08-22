-- 064_acciones.sql — el ciclo se cierra: una recomendación se puede ejecutar.
--
-- Chasqui detecta, explica, cuantifica y recomienda. **Ejecutar no existe**: es
-- el único eslabón de los cinco que la auditoría marcó en rojo. Ninguna
-- recomendación tiene acción, nada se registra y nada se mide después.
--
-- Y se nota en los datos: `v_perfil_negocio.acciones.por_accion` viene dando 0
-- desde B4, que es precisamente la medida de si el ciclo está cerrado.
--
-- LAS TRES ACCIONES
--
--   ✅ Ya lo hice          → resuelta, `cerrada_por = 'accion_usuario'`
--   ⏭️ No aplica           → ignorada
--   💲 Aplicar el precio   → escribe el precio sugerido en `conocimiento` y
--                            cierra la recomendación
--
-- La distinción entre `cerrada_por = 'dato'` y `'accion_usuario'`, que B2 dejó
-- preparada sin poder usarla, empieza a llenarse hoy. No es cosmética: "el
-- margen subió" y "el dueño dice que lo arregló" son evidencias de calidad muy
-- distinta, y D3 va a necesitar separarlas para medir si algo sirvió.
--
-- POR QUÉ LOS BOTONES NO VIAJAN EN EL INFORME
--
-- La tentación es poner tres botones debajo de cada recomendación. No se puede
-- y no conviene: el informe se arma en `ejecucion_preparar`, y las filas de
-- `recomendaciones` recién existen al cerrar (B2), así que en el momento de
-- render todavía no hay a qué apuntar. Además el teclado de un chat topa en 6
-- filas (027) y ocho recomendaciones por tres acciones son veinticuatro.
--
-- Entonces el informe lleva UN botón —"Ya hice algo"— y todo lo demás se
-- resuelve al tocarlo, contra la tabla, que para entonces ya está escrita. De
-- paso el mismo camino sirve para el portal y para WhatsApp sin cambiar nada.
--
-- LO QUE NO HACE: medir si sirvió. Eso es D3, y usa el eje `resultado` que B2
-- dejó creado y que esta migración sigue sin escribir.

-- =============================================================================
-- 1. Las recomendaciones llevan sus datos accionables
-- =============================================================================
-- Hasta acá el precio sugerido vivía SOLO dentro de la frase "Subilo a $12.500 y
-- quedás en 20% de margen". Para poder aplicarlo había que parsear esa frase —y
-- una frase se reescribe cualquier día—. Ahora el número viaja aparte.
--
-- `datos` entra como columna 11 de las diez CTEs del UNION ALL (posicional, C5),
-- y de paso deja servida la cantidad a pedir que consume D2.
CREATE OR REPLACE FUNCTION recomendaciones_negocio(p_negocio_id bigint,
                                                   p_registro boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_margen_min   numeric := coalesce((parametro(p_negocio_id,'margen_minimo_pct'))::text::numeric, 20);
    v_deriva_ali   numeric := coalesce((parametro(p_negocio_id,'deriva_costo_alerta_pct'))::text::numeric, 8);
    v_dias_cob     numeric := coalesce((parametro(p_negocio_id,'dias_cobertura_min'))::text::numeric, 7);
    v_entrega      numeric := coalesce((parametro(p_negocio_id,'dias_entrega_proveedor'))::text::numeric, 4);
    v_seguridad    numeric := coalesce((parametro(p_negocio_id,'dias_stock_seguridad'))::text::numeric, 3);
    v_lenta        numeric := coalesce((parametro(p_negocio_id,'rotacion_lenta_dias'))::text::numeric, 60);
    v_margen_alto  numeric := coalesce((parametro(p_negocio_id,'margen_alto_pct'))::text::numeric, 35);
    v_dep_prov     numeric := coalesce((parametro(p_negocio_id,'dependencia_proveedor_pct'))::text::numeric, 50);
    v_pri_alta     numeric := coalesce((parametro(p_negocio_id,'prioridad_alta_pct'))::text::numeric, 2);
    v_pri_media    numeric := coalesce((parametro(p_negocio_id,'prioridad_media_pct'))::text::numeric, 0.5);
    -- >>> 055: la vara propia de cada tipo de impacto.
    v_pri_alta_u   numeric := coalesce((parametro(p_negocio_id,'prioridad_alta_unico_pct'))::text::numeric, 10);
    v_pri_media_u  numeric := coalesce((parametro(p_negocio_id,'prioridad_media_unico_pct'))::text::numeric, 3);
    v_pri_alta_k   numeric := coalesce((parametro(p_negocio_id,'prioridad_alta_capital_pct'))::text::numeric, 50);
    v_pri_media_k  numeric := coalesce((parametro(p_negocio_id,'prioridad_media_capital_pct'))::text::numeric, 20);
    -- >>> 060: los umbrales de las reglas comparativas.
    v_sin_venta    numeric := coalesce((parametro(p_negocio_id,'dias_sin_venta_alerta'))::text::numeric, 45);
    v_min_ventas   numeric := coalesce((parametro(p_negocio_id,'ventas_minimas_historicas'))::text::numeric, 3);
    v_subidas      numeric := coalesce((parametro(p_negocio_id,'subidas_proveedor_alerta'))::text::numeric, 3);
    v_caida_margen numeric := coalesce((parametro(p_negocio_id,'caida_margen_pp_alerta'))::text::numeric, 3);
    v_caida_anual  numeric := coalesce((parametro(p_negocio_id,'caida_anual_pct_alerta'))::text::numeric, 15);
    v_meses        numeric;
    v_base_mes     numeric;   -- lo que mueve el negocio en un mes
    v_desde        date;
    v_hasta        date;      -- el "hoy" del análisis: la fecha más reciente
    v_mes_ref      date;      -- último mes COMPLETO de datos
    v_out          jsonb;
BEGIN
    -- Ventana real de los datos. Todo lo "por mes" se escala con esto, así que
    -- un negocio que cargó 15 días no ve cifras infladas ni desinfladas.
    SELECT min(fecha), max(fecha) INTO v_desde, v_hasta
    FROM mov_visibles WHERE negocio_id = p_negocio_id AND fecha IS NOT NULL;
    v_meses := coalesce(greatest((v_hasta - v_desde)::numeric / 30.0, 1), 1);

    -- >>> 060. El "hoy" de las reglas comparativas es `v_hasta`, no
    -- `current_date`. Un negocio que sube en agosto un archivo que termina en
    -- mayo no tiene tres meses sin vender: tiene tres meses sin cargar. Medir
    -- contra el reloj en vez de contra los datos convertiría cada carga
    -- atrasada en una avalancha de alertas falsas.
    --
    -- El mes de referencia es el último COMPLETO: comparar un agosto a medias
    -- contra un agosto entero del año pasado siempre daría caída.
    v_mes_ref := CASE
        WHEN v_hasta >= (date_trunc('month', v_hasta) + interval '1 month - 1 day')::date
        THEN date_trunc('month', v_hasta)::date
        ELSE (date_trunc('month', v_hasta) - interval '1 month')::date END;

    SELECT greatest(coalesce(sum(valor_total) FILTER (WHERE tipo = 'venta'),
                             sum(valor_total) FILTER (WHERE tipo = 'compra'), 0) / v_meses, 1)
      INTO v_base_mes
    FROM mov_visibles WHERE negocio_id = p_negocio_id;

    WITH
    -- Unidades compradas y vendidas por producto.
    base AS (
        SELECT m.producto_id,
               sum(m.cantidad) FILTER (WHERE m.tipo = 'compra') AS u_compradas,
               sum(m.cantidad) FILTER (WHERE m.tipo = 'venta')  AS u_vendidas
        FROM mov_visibles m
        WHERE m.negocio_id = p_negocio_id AND m.producto_id IS NOT NULL
        GROUP BY 1
    ),
    -- Precio promedio por proveedor, para saber si hay dónde comprar más barato.
    por_proveedor AS (
        SELECT m.producto_id,
               nullif(btrim(coalesce(m.raw ->> 'proveedor', '')), '') AS proveedor,
               sum(m.cantidad)                                        AS u,
               sum(m.valor_total) / nullif(sum(m.cantidad), 0)        AS precio_prom
        FROM mov_visibles m
        WHERE m.negocio_id = p_negocio_id AND m.tipo = 'compra'
          AND m.producto_id IS NOT NULL AND m.cantidad > 0 AND m.valor_total > 0
        GROUP BY 1, 2
    ),
    alternativa AS (
        SELECT producto_id,
               (array_agg(proveedor ORDER BY precio_prom))[1] AS prov_barato,
               round(min(precio_prom))                        AS precio_mejor,
               round(sum(u * precio_prom) / nullif(sum(u), 0)) AS precio_pagado,
               sum(u)                                         AS u_total
        FROM por_proveedor
        WHERE proveedor IS NOT NULL
        GROUP BY 1
        HAVING count(DISTINCT proveedor) > 1
    ),

    -- R1. El costo subió -----------------------------------------------------
    -- Tipo `mensual`: el sobrecosto se repite en cada compra futura.
    -- Las opciones se arman con unnest + agregado, no con jsonb_strip_nulls:
    -- strip_nulls solo borra campos NULL de OBJETOS, no elementos de un array,
    -- así que una opción que no aplica dejaría un `null` suelto en la lista.
    r_costo AS (
        SELECT 'costo' AS regla, ('producto:' || d.producto_id) AS clave_objeto,
               '📈' AS icono, p.nombre_canonico AS titulo,
               round(coalesce(d.costo_fin - d.costo_ini, 0)
                     * coalesce(b.u_compradas, 0) / v_meses) AS impacto_mes,
               'mensual'::text AS impacto_tipo,
               CASE WHEN round(coalesce(d.costo_fin - d.costo_ini, 0)
                               * coalesce(b.u_compradas, 0) / v_meses) > 0
                    THEN format('Al ritmo que lo comprás, son unos $%s más al mes.',
                                miles(round((d.costo_fin - d.costo_ini)
                                            * b.u_compradas / v_meses)))
                    ELSE '' END AS impacto_txt,
               format('El costo pasó de $%s a $%s: subió %s%% desde tu primera compra.',
                      miles(d.costo_ini), miles(d.costo_fin), fmt_decimal(d.deriva_pct))
               || CASE WHEN mp.precio_actual IS NOT NULL AND mp.precio_actual > 0
                       THEN format(' Con tu precio de venta actual el margen te queda en %s%%.',
                                   fmt_decimal(mp.margen_pct))
                       ELSE '' END AS problema,
               (SELECT coalesce(jsonb_agg(x), '[]'::jsonb) FROM unnest(ARRAY[
                  'Negociá el precio con tu proveedor antes de la próxima compra.'::text,
                  CASE WHEN a.prov_barato IS NOT NULL AND a.precio_mejor < d.costo_fin
                       THEN format('Comprale a %s, que te lo dejó a $%s.',
                                   a.prov_barato, miles(a.precio_mejor)) END,
                  CASE WHEN mp.precio_actual IS NOT NULL AND mp.precio_actual > 0
                            AND mp.margen_pct < v_margen_min
                       THEN format('Si no conseguís mejor precio, subí el precio de venta a $%s para volver a un margen de %s%%.',
                                   miles(round(d.costo_fin / nullif(1 - v_margen_min/100, 0))),
                                   fmt_decimal(v_margen_min)) END
                ]) AS x WHERE x IS NOT NULL) AS opciones,
               NULL::text AS origen_stock,
               -- >>> 064: lo mismo que dice la opción, pero como dato. El texto
               -- es para el dueño; esto es para que D1 pueda APLICARLO sin
               -- parsear una frase, que es la clase de cosa que se rompe la
               -- primera vez que alguien reescribe el copy.
               CASE WHEN mp.precio_actual IS NOT NULL AND mp.precio_actual > 0
                         AND mp.margen_pct < v_margen_min
                    THEN jsonb_build_object('precio_sugerido',
                           round(d.costo_fin / nullif(1 - v_margen_min/100, 0)))
                    ELSE '{}'::jsonb END AS datos
        FROM v_deriva_costo d
        JOIN productos p ON p.id = d.producto_id
        LEFT JOIN base b ON b.producto_id = d.producto_id
        LEFT JOIN alternativa a ON a.producto_id = d.producto_id
        LEFT JOIN v_margen_producto mp
               ON mp.producto_id = d.producto_id AND mp.negocio_id = d.negocio_id
        WHERE d.negocio_id = p_negocio_id AND d.deriva_pct >= v_deriva_ali
    ),

    -- R2. Estás pagando más de lo que ya conseguiste ------------------------
    -- Tipo `mensual`: la diferencia se paga en cada compra mientras no se cambie.
    r_proveedor AS (
        SELECT 'proveedor' AS regla, ('producto:' || a.producto_id) AS clave_objeto,
               '🧾' AS icono, p.nombre_canonico AS titulo,
               round((a.precio_pagado - a.precio_mejor) * a.u_total / v_meses) AS impacto_mes,
               'mensual'::text AS impacto_tipo,
               format('Estás dejando ir unos $%s al mes por comprarlo más caro de lo que ya lo conseguiste.',
                      miles(round((a.precio_pagado - a.precio_mejor) * a.u_total / v_meses))) AS impacto_txt,
               format('En promedio lo pagás a $%s, pero %s te lo dejó a $%s.',
                      miles(a.precio_pagado), a.prov_barato, miles(a.precio_mejor)) AS problema,
               jsonb_build_array(
                 format('Concentrá la compra de este producto en %s.', a.prov_barato),
                 'Usá ese precio como referencia para negociar con los demás.') AS opciones,
               NULL::text AS origen_stock,
               jsonb_build_object('proveedor_sugerido', a.prov_barato,
                                  'precio_mejor', a.precio_mejor) AS datos
        FROM alternativa a
        JOIN productos p ON p.id = a.producto_id
        WHERE a.precio_pagado > a.precio_mejor * 1.05
    ),

    -- R3. Margen por debajo del mínimo ---------------------------------------
    -- Tipo `mensual`: se deja de ganar en cada venta, mes tras mes.
    r_margen AS (
        SELECT 'margen' AS regla, ('producto:' || mp.producto_id) AS clave_objeto,
               '⚠️' AS icono, mp.nombre_canonico AS titulo,
               round(greatest(round(mp.costo_actual / nullif(1 - v_margen_min/100, 0))
                              - mp.precio_actual, 0)
                     * coalesce(b.u_vendidas, 0) / v_meses) AS impacto_mes,
               'mensual'::text AS impacto_tipo,
               CASE WHEN coalesce(b.u_vendidas, 0) > 0
                    THEN format('Son unos $%s al mes que no estás ganando.',
                                miles(round(greatest(round(mp.costo_actual / nullif(1 - v_margen_min/100, 0))
                                                     - mp.precio_actual, 0)
                                            * b.u_vendidas / v_meses)))
                    ELSE '' END AS impacto_txt,
               format('Lo vendés a $%s y te cuesta $%s: te deja %s%% de margen, por debajo del %s%% que deberías sostener.',
                      miles(mp.precio_actual), miles(mp.costo_actual),
                      fmt_decimal(mp.margen_pct), fmt_decimal(v_margen_min)) AS problema,
               jsonb_build_array(
                 format('Subilo a $%s y quedás en %s%% de margen.',
                        miles(round(mp.costo_actual / nullif(1 - v_margen_min/100, 0))),
                        fmt_decimal(v_margen_min)),
                 'Si no podés subir el precio, negociá el costo o buscá otra marca equivalente.') AS opciones,
               NULL::text AS origen_stock,
               jsonb_build_object('precio_sugerido',
                 round(mp.costo_actual / nullif(1 - v_margen_min/100, 0))) AS datos
        FROM v_margen_producto mp
        LEFT JOIN base b ON b.producto_id = mp.producto_id
        WHERE mp.negocio_id = p_negocio_id
          AND mp.precio_actual IS NOT NULL AND mp.precio_actual > 0
          AND mp.costo_actual IS NOT NULL
          AND mp.margen_pct < v_margen_min
    ),

    -- R4. Se agota, y cuánto comprar ----------------------------------------
    -- Tipo `unico`: es el lucro cesante de UN ciclo de entrega. Si se repone a
    -- tiempo no vuelve a ocurrir; no es una fuga mensual.
    -- La cantidad es la del ciclo completo: lo que se vende mientras el
    -- proveedor entrega, más el colchón. Es la cuenta que un tendero no hace y
    -- que decide entre quedarse sin producto o dormir la plata.
    r_agota AS (
        SELECT 'agota' AS regla, ('producto:' || r.producto_id) AS clave_objeto,
               '🕐' AS icono, p.nombre_canonico AS titulo,
               round(r.unidades_por_dia * v_entrega
                     * coalesce(mp.precio_actual, 0)) AS impacto_mes,
               'unico'::text AS impacto_tipo,
               CASE WHEN coalesce(mp.precio_actual, 0) > 0
                    THEN format('Si te quedás sin producto, son unos $%s que dejás de vender mientras llega el pedido.',
                                miles(round(r.unidades_por_dia * v_entrega * mp.precio_actual)))
                    ELSE '' END AS impacto_txt,
               -- Cobertura negativa = vendió más unidades de las que registró
               -- comprando. Decir "te alcanza para -95 días" no significa nada;
               -- lo que pasa es que ya no queda o falta cargar compras.
               CASE WHEN r.dias_cobertura < 0
                    THEN format('Por lo que cargaste ya no te queda: vendiste más de lo que registraste comprando. Vendés %s por día.',
                                unidades_es(r.unidades_por_dia))
                    ELSE format('Te alcanza para %s días y vendés %s por día.',
                                fmt_decimal(r.dias_cobertura),
                                unidades_es(r.unidades_por_dia))
               END
               || CASE WHEN r.origen_stock = 'estimado'
                       THEN ' Ojo: es una estimación de lo comprado menos lo vendido, no un conteo tuyo.'
                       ELSE '' END AS problema,
               jsonb_build_array(
                 format('Pedí %s: es lo que vendés en los %s días que demora el proveedor más %s días de colchón.',
                        unidades_es(ceil(r.unidades_por_dia * (v_entrega + v_seguridad))),
                        fmt_decimal(v_entrega), fmt_decimal(v_seguridad)),
                 'Si el proveedor demora más de lo normal, pedí antes, no más cantidad.') AS opciones,
               r.origen_stock,
               -- La cantidad a pedir, ya calculada: es lo que consume D2 para
               -- armar la lista de compra.
               jsonb_build_object('unidades_pedir',
                 ceil(r.unidades_por_dia * (v_entrega + v_seguridad))) AS datos
        FROM v_rotacion_producto r
        JOIN productos p ON p.id = r.producto_id
        LEFT JOIN v_margen_producto mp
               ON mp.producto_id = r.producto_id AND mp.negocio_id = r.negocio_id
        WHERE r.negocio_id = p_negocio_id
          AND r.dias_cobertura IS NOT NULL AND r.dias_cobertura < v_dias_cob
          AND r.unidades_por_dia > 0
    ),

    -- R5. Plata quieta: mucho inventario para lo que rota --------------------
    -- Tipo `capital`: no es plata que se pierde, es plata que existe y está
    -- inmóvil. Por eso su vara es varias veces más alta que la de una fuga.
    r_quieto AS (
        SELECT 'quieto' AS regla, ('producto:' || r.producto_id) AS clave_objeto,
               CASE WHEN mp.margen_pct >= v_margen_alto THEN '💰' ELSE '📦' END AS icono,
               p.nombre_canonico AS titulo,
               round(bal.balance * coalesce(mp.costo_actual, 0)) AS impacto_mes,
               'capital'::text AS impacto_tipo,
               CASE WHEN coalesce(mp.costo_actual, 0) > 0
                    THEN format('Tenés $%s inmovilizados en esa mercancía.',
                                miles(round(bal.balance * mp.costo_actual)))
                    ELSE '' END AS impacto_txt,
               format('Tenés inventario para %s días y solo vendés %s unidades por día.',
                      fmt_decimal(r.dias_cobertura), fmt_decimal(r.unidades_por_dia))
               || CASE WHEN bal.origen_stock = 'estimado'
                       THEN ' Ojo: es una estimación de lo comprado menos lo vendido, no un conteo tuyo.'
                       ELSE '' END AS problema,
               CASE WHEN mp.margen_pct >= v_margen_alto
                    THEN jsonb_build_array(
                           format('Te deja %s%% de margen: empujalo con una promoción o ponelo a la vista, en vez de rematarlo.',
                                  fmt_decimal(mp.margen_pct)),
                           'No vuelvas a comprarlo hasta bajar lo que tenés.')
                    ELSE jsonb_build_array(
                           'No vuelvas a comprarlo hasta agotar lo que tenés.',
                           'Si sigue sin moverse, sacalo con descuento antes de que se venza o pase de moda.')
               END AS opciones,
               bal.origen_stock,
               '{}'::jsonb AS datos
        FROM v_rotacion_producto r
        JOIN productos p ON p.id = r.producto_id
        JOIN v_balance_unidades bal
          ON bal.producto_id = r.producto_id AND bal.negocio_id = r.negocio_id
        LEFT JOIN v_margen_producto mp
               ON mp.producto_id = r.producto_id AND mp.negocio_id = r.negocio_id
        WHERE r.negocio_id = p_negocio_id
          AND r.dias_cobertura IS NOT NULL AND r.dias_cobertura > v_lenta
          AND bal.balance > 0
    ),

    -- R6. Un solo proveedor concentra las compras ----------------------------
    -- Tipo `mensual` con impacto 0: es un riesgo, no una pérdida en curso. El
    -- tipo da igual para la prioridad —entra fija en media— pero se declara
    -- para que ningún consumidor futuro tenga que tratarla como excepción.
    gasto_prov AS (
        SELECT nullif(btrim(coalesce(m.raw ->> 'proveedor', '')), '') AS proveedor,
               sum(m.valor_total) AS gasto
        FROM mov_visibles m
        WHERE m.negocio_id = p_negocio_id AND m.tipo = 'compra'
        GROUP BY 1
    ),
    r_dependencia AS (
        SELECT 'dependencia' AS regla, ('proveedor:' || g.proveedor) AS clave_objeto,
               '🔎' AS icono, 'Dependés de un solo proveedor' AS titulo,
               0::numeric AS impacto_mes, 'mensual'::text AS impacto_tipo, '' AS impacto_txt,
               format('%s concentra el %s%% de todo lo que comprás ($%s).',
                      g.proveedor,
                      fmt_decimal(round(g.gasto * 100.0 / nullif(t.total, 0), 1)),
                      miles(round(g.gasto))) AS problema,
               jsonb_build_array(
                 'Conseguí un segundo proveedor para los productos que más te pesan, aunque le compres poco.',
                 'Con dos precios en la mano tenés con qué negociar; con uno solo, aceptás lo que te digan.') AS opciones,
               NULL::text AS origen_stock,
               '{}'::jsonb AS datos
        FROM gasto_prov g,
             LATERAL (SELECT sum(gasto) AS total FROM gasto_prov) t
        WHERE g.proveedor IS NOT NULL AND t.total > 0
          AND g.gasto * 100.0 / t.total >= v_dep_prov
    ),

    -- =====================================================================
    -- NIVEL 1 COMPLETO (060): reglas contra el propio historial del negocio
    -- =====================================================================
    -- Las seis de arriba miran una foto: cómo está el negocio hoy. Estas cuatro
    -- miran la película. Tres de ellas se calculan directamente sobre
    -- `mov_visibles` y no sobre los snapshots, a propósito: un hecho que está en
    -- los movimientos —cuándo fue la última venta, qué precio pagó cada compra—
    -- es más preciso ahí, y sobre todo no depende de cada cuánto se corrieron
    -- análisis. Solo el margen necesita snapshots, porque un margen no es un
    -- hecho registrado sino una medición: sale de comparar el costo y el precio
    -- vigentes en un momento, y ese momento hay que haberlo guardado.

    -- R7. Dejó de venderse -------------------------------------------------
    -- El producto tenía ritmo y se paró. Es la regla que un dueño agradece
    -- porque el producto que no se vende no molesta: simplemente desaparece de
    -- la vista mientras ocupa plata y espacio.
    venta_hist AS (
        SELECT m.producto_id,
               min(m.fecha) AS primera, max(m.fecha) AS ultima,
               count(*)     AS n_ventas,
               sum(m.valor_total) AS importe
        FROM mov_visibles m
        WHERE m.negocio_id = p_negocio_id AND m.tipo = 'venta'
          AND m.producto_id IS NOT NULL AND m.fecha IS NOT NULL
        GROUP BY 1
    ),
    r_sin_ventas AS (
        SELECT 'sin_ventas' AS regla, ('producto:' || v.producto_id) AS clave_objeto,
               '📉' AS icono, p.nombre_canonico AS titulo,
               -- Lo que dejó de entrar por mes, medido con su propio ritmo
               -- mientras se vendía, no con el del negocio entero.
               round(v.importe / greatest((v.ultima - v.primera)::numeric / 30.0, 1)) AS impacto_mes,
               'mensual'::text AS impacto_tipo,
               format('Mientras se vendía te entraban unos $%s al mes por ese producto.',
                      miles(round(v.importe / greatest((v.ultima - v.primera)::numeric / 30.0, 1)))) AS impacto_txt,
               format('Lo vendiste %s veces y la última fue el %s: van %s días sin moverse.',
                      v.n_ventas, to_char(v.ultima, 'DD/MM/YYYY'), (v_hasta - v.ultima)) AS problema,
               jsonb_build_array(
                 'Fijate si todavía lo tenés en el mostrador y a la vista: lo que no se ve no se vende.',
                 'Si dejaste de conseguirlo o lo sacaste vos, ignorá este aviso; si no, algo cambió y conviene saber qué.') AS opciones,
               NULL::text AS origen_stock,
               '{}'::jsonb AS datos
        FROM venta_hist v
        JOIN productos p ON p.id = v.producto_id
        WHERE (v_hasta - v.ultima) > v_sin_venta
          AND v.n_ventas >= v_min_ventas
          -- Sin un historial que dé para medir un ritmo, "dejó de venderse" no
          -- significa nada: puede no haber empezado nunca.
          AND (v.ultima - v.primera) >= 14
    ),

    -- R8. El proveedor viene subiendo --------------------------------------
    -- Distinta de R1: R1 dice que el costo está más alto que al principio, que
    -- puede ser un salto único. Esta dice que sube UNA Y OTRA VEZ con el mismo
    -- proveedor, que es un patrón de negociación y se responde distinto.
    compras_serie AS (
        SELECT m.producto_id,
               nullif(btrim(coalesce(m.raw ->> 'proveedor', '')), '') AS proveedor,
               m.fecha, m.cantidad,
               m.valor_total / nullif(m.cantidad, 0) AS precio
        FROM mov_visibles m
        WHERE m.negocio_id = p_negocio_id AND m.tipo = 'compra'
          AND m.producto_id IS NOT NULL AND m.cantidad > 0 AND m.valor_total > 0
          AND m.fecha IS NOT NULL AND m.fecha > v_hasta - interval '1 year'
    ),
    compras_delta AS (
        SELECT producto_id, proveedor, fecha, cantidad, precio,
               lag(precio) OVER (PARTITION BY producto_id, proveedor ORDER BY fecha) AS previo
        FROM compras_serie WHERE proveedor IS NOT NULL
    ),
    sube AS (
        SELECT producto_id, proveedor,
               -- El 1% de margen evita contar como "subida" el redondeo de un
               -- precio que en realidad no se movió.
               count(*) FILTER (WHERE previo IS NOT NULL AND precio > previo * 1.01) AS subidas,
               (array_agg(precio ORDER BY fecha))[1]      AS precio_ini,
               (array_agg(precio ORDER BY fecha DESC))[1] AS precio_fin,
               sum(cantidad) AS unidades
        FROM compras_delta
        GROUP BY 1, 2
    ),
    r_prov_sube AS (
        -- Un producto puede tener varios proveedores subiendo; se reporta el
        -- que más plata cuesta, igual que el resto de las reglas reportan lo
        -- peor de cada frente y no una lista.
        SELECT DISTINCT ON (s.producto_id)
               'proveedor_sube' AS regla, ('producto:' || s.producto_id) AS clave_objeto,
               '📈' AS icono, p.nombre_canonico AS titulo,
               round((s.precio_fin - s.precio_ini) * s.unidades / least(v_meses, 12)) AS impacto_mes,
               'mensual'::text AS impacto_tipo,
               format('Al ritmo que lo comprás son unos $%s más al mes que hace un año.',
                      miles(round((s.precio_fin - s.precio_ini) * s.unidades / least(v_meses, 12)))) AS impacto_txt,
               format('%s te subió el precio %s veces en el último año: de $%s a $%s.',
                      s.proveedor, s.subidas, miles(round(s.precio_ini)), miles(round(s.precio_fin))) AS problema,
               jsonb_build_array(
                 format('Preguntale a %s por qué, con los precios anteriores en la mano.', s.proveedor),
                 'Pedile precio a otro para este producto: no para cambiarte, para tener con qué negociar.') AS opciones,
               NULL::text AS origen_stock,
               jsonb_build_object('proveedor', s.proveedor) AS datos
        FROM sube s
        JOIN productos p ON p.id = s.producto_id
        WHERE s.subidas >= v_subidas AND s.precio_fin > s.precio_ini
        ORDER BY s.producto_id, (s.precio_fin - s.precio_ini) * s.unidades DESC
    ),

    -- R9. El margen se viene cayendo ---------------------------------------
    -- La única de las cuatro que necesita snapshots (B1). Se piden los dos
    -- últimos COMPLETOS: los parciales del backfill no traen el margen por
    -- producto, y compararse contra un hueco no es compararse.
    snaps AS (
        SELECT metricas, row_number() OVER (ORDER BY fecha DESC) AS n
        FROM snapshots_negocio
        WHERE negocio_id = p_negocio_id
          AND coalesce((metricas -> 'parcial')::boolean, false) = false
        ORDER BY fecha DESC LIMIT 2
    ),
    margen_hist AS (
        SELECT s.n, e.producto_id, e.margen_pct
        FROM snaps s,
             LATERAL jsonb_to_recordset(s.metricas -> 'margenes')
               AS e(producto_id bigint, margen_pct numeric)
    ),
    r_margen_cae AS (
        SELECT 'margen_cae' AS regla, ('producto:' || mp.producto_id) AS clave_objeto,
               '📉' AS icono, mp.nombre_canonico AS titulo,
               round((h2.margen_pct - mp.margen_pct) / 100.0
                     * coalesce(v.importe, 0) / v_meses) AS impacto_mes,
               'mensual'::text AS impacto_tipo,
               CASE WHEN coalesce(v.importe, 0) > 0
                    THEN format('Son unos $%s al mes que antes te quedaban y ahora no.',
                                miles(round((h2.margen_pct - mp.margen_pct) / 100.0
                                            * v.importe / v_meses)))
                    ELSE '' END AS impacto_txt,
               format('Tu margen viene bajando dos periodos seguidos: %s%%, después %s%%, y ahora %s%%.',
                      fmt_decimal(h2.margen_pct), fmt_decimal(h1.margen_pct),
                      fmt_decimal(mp.margen_pct)) AS problema,
               jsonb_build_array(
                 'No es un mal mes: es una tendencia. Mirá si subió el costo o si bajaste el precio sin darte cuenta.',
                 format('Para volver al %s%% de antes, el precio tendría que ser $%s.',
                        fmt_decimal(h2.margen_pct),
                        miles(round(mp.costo_actual / nullif(1 - h2.margen_pct/100, 0))))) AS opciones,
               NULL::text AS origen_stock,
               jsonb_build_object('precio_sugerido',
                 round(mp.costo_actual / nullif(1 - h2.margen_pct/100, 0))) AS datos
        FROM v_margen_producto mp
        JOIN margen_hist h1 ON h1.n = 1 AND h1.producto_id = mp.producto_id
        JOIN margen_hist h2 ON h2.n = 2 AND h2.producto_id = mp.producto_id
        LEFT JOIN venta_hist v ON v.producto_id = mp.producto_id
        WHERE mp.negocio_id = p_negocio_id
          AND mp.margen_pct IS NOT NULL AND mp.costo_actual IS NOT NULL
          AND h1.margen_pct IS NOT NULL AND h2.margen_pct IS NOT NULL
          -- Dos caídas seguidas, no una. Un solo mes malo es ruido.
          AND mp.margen_pct < h1.margen_pct
          AND h1.margen_pct  < h2.margen_pct
          AND (h2.margen_pct - mp.margen_pct) >= v_caida_margen
    ),

    -- R10. Vendés menos que el año pasado ----------------------------------
    -- La comparación que un tendero hace de memoria y casi siempre mal. Necesita
    -- trece meses de historia visible: por eso A1 tenía que ir primero — con el
    -- plan free borrando el pasado, esta regla no podía existir.
    anual AS (
        SELECT
          coalesce(sum(valor_total) FILTER (
            WHERE fecha >= v_mes_ref AND fecha < v_mes_ref + interval '1 month'), 0) AS ahora,
          coalesce(sum(valor_total) FILTER (
            WHERE fecha >= v_mes_ref - interval '1 year'
              AND fecha <  v_mes_ref - interval '1 year' + interval '1 month'), 0) AS antes
        FROM mov_visibles
        WHERE negocio_id = p_negocio_id AND tipo = 'venta' AND fecha IS NOT NULL
    ),
    r_vs_ano AS (
        SELECT 'vs_ano_anterior' AS regla, 'negocio'::text AS clave_objeto,
               '📅' AS icono, 'Vendés menos que el año pasado' AS titulo,
               round(a.antes - a.ahora) AS impacto_mes,
               'mensual'::text AS impacto_tipo,
               format('Son $%s menos que en el mismo mes del año pasado.',
                      miles(round(a.antes - a.ahora))) AS impacto_txt,
               format('En %s vendiste $%s. El mismo mes del año pasado habías vendido $%s: %s%% menos.',
                      mes_es(v_mes_ref), miles(round(a.ahora)), miles(round(a.antes)),
                      fmt_decimal(round((a.antes - a.ahora) * 100.0 / nullif(a.antes, 0), 1))) AS problema,
               jsonb_build_array(
                 'Mirá qué productos se vendían entonces y ahora no: ahí suele estar la respuesta.',
                 'Si el año pasado tuviste algo puntual —una temporada, un cliente grande— no es comparable y podés ignorarlo.') AS opciones,
               NULL::text AS origen_stock,
               '{}'::jsonb AS datos
        FROM anual a
        WHERE a.antes > 0
          AND (a.antes - a.ahora) * 100.0 / a.antes >= v_caida_anual
    ),

    todas AS (
        SELECT * FROM r_costo        UNION ALL
        SELECT * FROM r_proveedor    UNION ALL
        SELECT * FROM r_margen       UNION ALL
        SELECT * FROM r_agota        UNION ALL
        SELECT * FROM r_quieto       UNION ALL
        SELECT * FROM r_dependencia  UNION ALL
        -- >>> 060: las comparativas.
        SELECT * FROM r_sin_ventas   UNION ALL
        SELECT * FROM r_prov_sube    UNION ALL
        SELECT * FROM r_margen_cae   UNION ALL
        SELECT * FROM r_vs_ano
    ),
    -- La prioridad sigue siendo el impacto medido contra lo que mueve el
    -- negocio, pero cada tipo tiene su vara (055). La dependencia de proveedor
    -- no tiene impacto calculable y entra fija en media: es un riesgo, no una
    -- pérdida que ya esté ocurriendo.
    --
    -- `relevancia` = cuántas veces la recomendación supera el umbral MEDIA de su
    -- propio tipo. Es lo único comparable entre tipos, y es lo que ordena dentro
    -- de una misma prioridad. Antes ordenaba `impacto_mes` crudo, y un capital
    -- acumulado le ganaba siempre a una fuga mensual por ser un número mayor,
    -- aunque significara menos.
    priorizadas AS (
        SELECT t.regla, t.clave_objeto, t.datos,
               t.icono, t.titulo, t.problema, t.opciones, t.impacto_txt,
               t.origen_stock, t.impacto_tipo,
               coalesce(t.impacto_mes, 0) AS impacto_mes,
               CASE WHEN t.regla = 'dependencia' THEN 'media'
                    WHEN u.pct >= u.alta  THEN 'alta'
                    WHEN u.pct >= u.media THEN 'media'
                    ELSE 'baja' END AS prioridad,
               CASE WHEN t.regla = 'dependencia' THEN 0
                    ELSE u.pct / greatest(u.media, 0.0001) END AS relevancia,
               -- El tope por regla: lo peor de cada frente, no el ranking de
               -- pesos, que se llena con la regla que más productos toca.
               -- Dentro de una regla el tipo es el mismo, así que acá el monto
               -- crudo sí compara bien.
               row_number() OVER (PARTITION BY t.regla
                                  ORDER BY coalesce(t.impacto_mes, 0) DESC) AS rn
        FROM todas t
        CROSS JOIN LATERAL (
            SELECT coalesce(t.impacto_mes, 0) * 100.0 / v_base_mes AS pct,
                   CASE t.impacto_tipo WHEN 'unico'   THEN v_pri_alta_u
                                       WHEN 'capital' THEN v_pri_alta_k
                                       ELSE v_pri_alta END          AS alta,
                   CASE t.impacto_tipo WHEN 'unico'   THEN v_pri_media_u
                                       WHEN 'capital' THEN v_pri_media_k
                                       ELSE v_pri_media END         AS media
        ) u
        WHERE coalesce(t.titulo, '') <> ''
    ),
    -- >>> 059. Hasta acá el tope (2 por regla, 8 en total) se aplicaba en la
    -- consulta final y lo que quedaba afuera se perdía. Para persistir hace
    -- falta distinguir dos conjuntos que antes eran uno:
    --
    --   lo DETECTADO — todos los problemas que las reglas encontraron.
    --   lo MOSTRADO  — los que entraron al informe después de los topes.
    --
    -- Sin esa distinción, una recomendación abierta que hoy no aparece podría
    -- estar ausente porque el problema se arregló O porque la empujaron fuera
    -- del top 8, y cerrarla como "resuelta" en el segundo caso sería mentir.
    visibles AS (
        SELECT regla, clave_objeto,
               row_number() OVER (
                 ORDER BY CASE prioridad WHEN 'alta' THEN 1 WHEN 'media' THEN 2 ELSE 3 END,
                          relevancia DESC) AS pos
        FROM priorizadas WHERE rn <= 2
    ),
    salida AS (
        SELECT p.*, coalesce(v.pos <= 8, false) AS en_informe
        FROM priorizadas p
        LEFT JOIN visibles v
               ON v.regla = p.regla AND v.clave_objeto = p.clave_objeto
        -- En modo informe sale lo de siempre; en modo registro, todo.
        WHERE p_registro OR coalesce(v.pos, 2147483647) <= 8
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'icono', icono, 'prioridad', prioridad, 'titulo', titulo,
             'problema', problema,
             'impacto', coalesce(impacto_txt, ''),
             'impacto_mes', impacto_mes,
             -- >>> 055: qué clase de impacto es el número de arriba.
             --   mensual — pesos por mes que se van a seguir yendo
             --   unico   — pesos una sola vez, si el evento ocurre
             --   capital — pesos que existen y están inmóviles
             'impacto_tipo', impacto_tipo,
             'opciones', opciones,
             -- >>> 054: de dónde sale el stock con el que se calculó
             -- esto. 'estimado' = comprado menos vendido, sin conteo.
             'origen_stock', origen_stock)
             -- >>> 059: la identidad de la recomendación viaja SOLO en modo
             -- registro. En modo informe el JSON queda como estaba, que es lo
             -- que ve el modelo y lo que audita validar_cifras: no tiene por
             -- qué enterarse de una clave interna como 'producto:9'.
             || CASE WHEN p_registro
                     THEN jsonb_build_object('regla', regla,
                                             'clave_objeto', clave_objeto,
                                             'datos', coalesce(datos, '{}'::jsonb),
                                             'en_informe', en_informe)
                     ELSE '{}'::jsonb END
             ORDER BY CASE prioridad WHEN 'alta' THEN 1 WHEN 'media' THEN 2 ELSE 3 END,
                      relevancia DESC), '[]'::jsonb)
      INTO v_out
    FROM salida s;

    RETURN v_out;
END;
$$;


ALTER TABLE recomendaciones
    ADD COLUMN IF NOT EXISTS datos jsonb NOT NULL DEFAULT '{}'::jsonb;

-- El icono ya venía en el JSON de `recomendaciones_negocio` y no se estaba
-- guardando. Sirve: en una lista de cinco renglones, el 📦 y el 🕐 dicen de qué
-- va cada uno antes de leer el texto.
ALTER TABLE recomendaciones
    ADD COLUMN IF NOT EXISTS icono text;

COMMENT ON COLUMN recomendaciones.datos IS
  'Lo accionable de la recomendación como dato y no como frase: '
  'precio_sugerido, unidades_pedir, proveedor_sugerido. Lo consume D1 para '
  'aplicar y D2 para armar la lista de compra.';

-- El registro guarda también los datos accionables.
CREATE OR REPLACE FUNCTION recomendaciones_registrar(p_negocio_id   bigint,
                                                     p_ejecucion_id bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_detectadas jsonb;
    v_nuevas     int := 0;
    v_seguian    int := 0;
    v_resueltas  int := 0;
    v_caducadas  int := 0;
    v_vistas     int := 0;
BEGIN
    v_detectadas := recomendaciones_negocio(p_negocio_id, true);


    -- ---- 1. Las que siguen -------------------------------------------------
    -- Se refrescan las cifras: el impacto cambia entre periodos y lo que
    -- interesa mostrar es el de hoy. `detectada_en` NO se toca — es cuándo
    -- empezó el problema, y es media respuesta a "¿desde cuándo vengo así?".
    WITH upd AS (
        UPDATE recomendaciones r
           SET titulo = d.titulo, problema = d.problema, impacto = d.impacto,
               impacto_mes = d.impacto_mes, impacto_tipo = d.impacto_tipo,
               prioridad = d.prioridad, opciones = coalesce(d.opciones, '[]'::jsonb),
               origen_stock = d.origen_stock, icono = d.icono,
               datos = coalesce(d.datos, '{}'::jsonb), revisada_en = now()
          FROM (SELECT * FROM jsonb_to_recordset(v_detectadas) AS e(
                  regla text, clave_objeto text, titulo text, problema text,
                  impacto text, impacto_mes numeric, impacto_tipo text,
                  prioridad text, opciones jsonb, origen_stock text,
                  datos jsonb, icono text, en_informe boolean)) d
         WHERE r.negocio_id = p_negocio_id AND r.regla = d.regla
           AND r.clave_objeto = d.clave_objeto
           AND r.estado IN ('nueva','vigente')
        RETURNING 1)
    SELECT count(*) INTO v_seguian FROM upd;

    -- ---- 2. Las que aparecen por primera vez -------------------------------
    WITH ins AS (
        INSERT INTO recomendaciones (negocio_id, regla, clave_objeto, titulo,
                 problema, impacto, impacto_mes, impacto_tipo, prioridad,
                 opciones, origen_stock, datos, icono, ejecucion_id)
        SELECT p_negocio_id, d.regla, d.clave_objeto, d.titulo, d.problema,
               d.impacto, d.impacto_mes, d.impacto_tipo, d.prioridad,
               coalesce(d.opciones, '[]'::jsonb), d.origen_stock,
               coalesce(d.datos, '{}'::jsonb), d.icono, p_ejecucion_id
        FROM (SELECT * FROM jsonb_to_recordset(v_detectadas) AS e(
                  regla text, clave_objeto text, titulo text, problema text,
                  impacto text, impacto_mes numeric, impacto_tipo text,
                  prioridad text, opciones jsonb, origen_stock text,
                  datos jsonb, icono text, en_informe boolean)) d
        WHERE NOT EXISTS (
            SELECT 1 FROM recomendaciones r
             WHERE r.negocio_id = p_negocio_id AND r.regla = d.regla
               AND r.clave_objeto = d.clave_objeto
               AND r.estado IN ('nueva','vigente'))
        RETURNING 1)
    SELECT count(*) INTO v_nuevas FROM ins;

    -- ---- 3. Las que ya no están --------------------------------------------
    WITH cerradas AS (
        UPDATE recomendaciones r
           SET estado      = CASE WHEN recomendacion_objeto_evaluable(p_negocio_id, r.clave_objeto)
                                  THEN 'resuelta' ELSE 'caducada' END,
               cerrada_por = CASE WHEN recomendacion_objeto_evaluable(p_negocio_id, r.clave_objeto)
                                  THEN 'dato' ELSE 'sin_datos' END,
               cerrada_en  = now(), revisada_en = now()
         WHERE r.negocio_id = p_negocio_id
           AND r.estado IN ('nueva','vigente')
           -- Basta con esto: el paso 1 solo tocó las que SÍ están detectadas,
           -- así que no hay forma de que una de ellas caiga acá.
           AND NOT EXISTS (SELECT 1 FROM jsonb_to_recordset(v_detectadas)
                                    AS d(regla text, clave_objeto text)
                            WHERE d.regla = r.regla AND d.clave_objeto = r.clave_objeto)
        RETURNING estado)
    SELECT count(*) FILTER (WHERE estado = 'resuelta'),
           count(*) FILTER (WHERE estado = 'caducada')
      INTO v_resueltas, v_caducadas
    FROM cerradas;

    -- ---- 4. Lo que llegó al informe cuenta como visto ----------------------
    -- Solo lo que entró al top 8. Marcar como vista una recomendación que el
    -- dueño nunca leyó dejaría el dato inservible el día que D1 le pregunte
    -- "¿hiciste algo con esto?".
    WITH marcadas AS (
        UPDATE recomendaciones r
           SET estado = 'vigente',
               vista_en = coalesce(r.vista_en, now()),
               veces_vista = r.veces_vista + 1
          FROM (SELECT * FROM jsonb_to_recordset(v_detectadas)
                         AS e(regla text, clave_objeto text, en_informe boolean)) d
         WHERE r.negocio_id = p_negocio_id AND r.regla = d.regla
           AND r.clave_objeto = d.clave_objeto
           AND d.en_informe
           AND r.estado IN ('nueva','vigente')
        RETURNING 1)
    SELECT count(*) INTO v_vistas FROM marcadas;

    RETURN jsonb_build_object('nuevas', v_nuevas, 'seguian', v_seguian,
                              'resueltas', v_resueltas, 'caducadas', v_caducadas,
                              'mostradas', v_vistas);
END;
$$;


-- =============================================================================
-- 2. La acción
-- =============================================================================
-- Un solo punto de escritura para las tres. Valida que la recomendación sea del
-- negocio que la está tocando y que siga abierta: un botón de un informe viejo
-- no puede cerrar algo dos veces ni tocar lo de otro negocio.
CREATE OR REPLACE FUNCTION recomendacion_accion(p_reco_id    bigint,
                                                p_negocio_id bigint,
                                                p_accion     text,
                                                p_usuario_id bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_r      record;
    v_precio numeric;
BEGIN
    SELECT * INTO v_r FROM recomendaciones
    WHERE id = p_reco_id AND negocio_id = p_negocio_id
      AND estado IN ('nueva','vigente');

    IF v_r.id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_encontrada');
    END IF;

    IF p_accion = 'hice' THEN
        UPDATE recomendaciones
           SET estado = 'resuelta', cerrada_por = 'accion_usuario',
               cerrada_en = now()
         WHERE id = p_reco_id;
        RETURN jsonb_build_object('ok', true, 'accion', 'hice',
                                  'titulo', v_r.titulo);

    ELSIF p_accion = 'no_aplica' THEN
        UPDATE recomendaciones
           SET estado = 'ignorada', cerrada_por = 'accion_usuario',
               cerrada_en = now()
         WHERE id = p_reco_id;
        RETURN jsonb_build_object('ok', true, 'accion', 'no_aplica',
                                  'titulo', v_r.titulo);

    ELSIF p_accion = 'precio' THEN
        v_precio := nullif(v_r.datos ->> 'precio_sugerido', '')::numeric;
        IF v_precio IS NULL OR v_precio <= 0 THEN
            RETURN jsonb_build_object('ok', false, 'error', 'sin_precio');
        END IF;

        -- Escribe en `conocimiento` tipo 'precio', que ya existe y ya tiene
        -- pantalla en el portal. La clave es el título de la recomendación —el
        -- nombre canónico del producto—, así que aplicar dos veces actualiza en
        -- vez de duplicar.
        PERFORM conocimiento_guardar(
          p_negocio_id, 'precio', v_r.titulo,
          format('Precio sugerido por Chasqui a partir de %s.', v_r.regla),
          v_r.titulo,
          jsonb_build_object('valor', v_precio, 'origen', 'recomendacion',
                             'recomendacion_id', p_reco_id),
          'chat', p_usuario_id);

        UPDATE recomendaciones
           SET estado = 'resuelta', cerrada_por = 'accion_usuario',
               cerrada_en = now()
         WHERE id = p_reco_id;

        RETURN jsonb_build_object('ok', true, 'accion', 'precio',
                                  'titulo', v_r.titulo,
                                  'precio', '$' || miles(v_precio));
    END IF;

    RETURN jsonb_build_object('ok', false, 'error', 'accion_desconocida');
END;
$$;

-- =============================================================================
-- 3. Los teclados
-- =============================================================================
-- Las abiertas, una por fila. El tope de 6 es el mismo de `teclado_markup`
-- (027): un teclado más largo que eso no se puede enviar, así que no se arma.
CREATE OR REPLACE FUNCTION teclado_recomendaciones(p_negocio_id bigint)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT coalesce(
             (SELECT jsonb_agg(jsonb_build_array(jsonb_build_object(
                       'texto', left(titulo, 40), 'dato', 'rec:ver:' || id))
                       ORDER BY orden)
              FROM (SELECT id, titulo,
                           row_number() OVER (
                             ORDER BY CASE prioridad WHEN 'alta' THEN 1
                                                     WHEN 'media' THEN 2 ELSE 3 END,
                                      impacto_mes DESC) AS orden
                    FROM recomendaciones
                    WHERE negocio_id = p_negocio_id AND estado IN ('nueva','vigente')
                    ORDER BY orden LIMIT 5) r),
             '[]'::jsonb)
           || jsonb_build_array(jsonb_build_array(jsonb_build_object(
                'texto', '⬅️ Volver', 'dato', '/ayuda')));
$$;

-- Las tres acciones de UNA recomendación. "Aplicar el precio" solo aparece si
-- hay un precio que aplicar: un botón que no puede funcionar es peor que no
-- tener botón.
CREATE OR REPLACE FUNCTION teclado_recomendacion(p_reco_id bigint)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_array(
             jsonb_build_array(jsonb_build_object(
               'texto', '✅ Ya lo hice', 'dato', 'rec:hice:' || r.id)),
             jsonb_build_array(jsonb_build_object(
               'texto', '⏭️ No aplica', 'dato', 'rec:no_aplica:' || r.id)))
           || CASE WHEN nullif(r.datos ->> 'precio_sugerido', '') IS NOT NULL
                   THEN jsonb_build_array(jsonb_build_array(jsonb_build_object(
                          'texto', '💲 Aplicar $' || miles((r.datos ->> 'precio_sugerido')::numeric),
                          'dato', 'rec:precio:' || r.id)))
                   ELSE '[]'::jsonb END
           || jsonb_build_array(jsonb_build_array(jsonb_build_object(
                'texto', '⬅️ Volver', 'dato', 'rec:list')))
    FROM recomendaciones r WHERE r.id = p_reco_id;
$$;

-- =============================================================================
-- 4. Los textos
-- =============================================================================
INSERT INTO plantillas (clave, cuerpo, formato) VALUES
('recomendacion.lista',
'📋 <b>Lo que te vengo diciendo</b>

Tocá lo que ya hayas hecho y lo cierro. Lo que no aplique a tu negocio también se puede sacar de la lista.',
 'html'),
('recomendacion.sin_pendientes',
'✨ No tenés nada pendiente ahora mismo.

Cuando analice tus próximos archivos y encuentre algo, te lo digo por acá.',
 'html'),
('recomendacion.detalle',
'{{icono}} <b>{{titulo}}</b>

{{problema}}

{{impacto}}

<i>Te lo vengo diciendo desde hace {{dias}} días.</i>',
 'html'),
('recomendacion.hecha',
'✅ Listo, cierro <b>{{titulo}}</b>.

Lo voy a revisar en el próximo análisis: si los números lo confirman, mejor todavía.',
 'html'),
('recomendacion.ignorada',
'⏭️ Entendido, saco <b>{{titulo}}</b> de la lista.

Si el problema vuelve a aparecer en tus números te lo digo de nuevo, pero no insisto con este.',
 'html'),
('recomendacion.precio_aplicado',
'💲 Guardé <b>{{precio}}</b> como precio de <b>{{titulo}}</b>.

Queda en tu lista de precios del portal. Ojo: yo no cambio el precio en tu punto de venta — eso lo hacés vos.',
 'html'),
('recomendacion.no_encontrada',
'🤔 Esa ya no está pendiente: o la cerraste antes, o el problema se resolvió solo.',
 'html'),
('recomendacion.sin_precio',
'🤔 Esa recomendación no tiene un precio para aplicar.',
 'html')
ON CONFLICT (clave) DO UPDATE
  SET cuerpo = EXCLUDED.cuerpo, formato = EXCLUDED.formato, activo = true;

-- El informe entregado ofrece la puerta de entrada. Un solo botón: el resto se
-- resuelve al tocarlo, cuando las filas ya existen.
UPDATE plantillas
   SET teclado = jsonb_build_array(
         jsonb_build_array(jsonb_build_object(
           'texto', '✅ Ya hice algo', 'dato', 'rec:list')))
 WHERE clave = 'ejecucion.entregada';

-- =============================================================================
-- 5. El router reconoce el prefijo
-- =============================================================================
-- Es exactamente lo que A4 vino a hacer barato: se reemplaza `router_ctx` y un
-- handler, y los otros cuatro quedan intactos. Antes esto obligaba a pegar las
-- 356 líneas del router entero.
CREATE OR REPLACE FUNCTION router_ctx(p_evento jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_usuario_id bigint;
    v_texto      text := btrim(coalesce(p_evento ->> 'texto', ''));
    v_cmd        text;
    v_arg        text;          -- resto del mensaje después del comando
    v_svc        text;          -- código que llegó por botón (svc:<codigo>)
    v_mod        text;          -- código de módulo (mod:/modayuda:)
    v_tip        text;          -- >>> 046: naturaleza del negocio (tipo:<codigo>)
    v_rec        text;          -- >>> 064: acción sobre una recomendación
    v_negocio_id bigint;
    v_autoriz    boolean;
    v_rol        rol_usuario;
    v_n_serv     int;
    v_consulta   boolean;
BEGIN
    -- El primer token y el resto. Se parte por espacio EN BLANCO, no por ' ':
    -- un "/saber" seguido de salto de línea es la forma natural de enseñarle
    -- algo largo, y con split_part(' ') el comando se comía el texto entero.
    v_cmd := lower(coalesce(substring(v_texto FROM '^\S+'), ''));
    v_arg := btrim(coalesce(substring(v_texto FROM '^\S+\s+(.*)$'), ''));
    IF v_texto LIKE 'svc:%' THEN
        v_svc := substring(v_texto FROM 5);
        v_cmd := 'svc';
    ELSIF v_texto LIKE 'mod:%' THEN
        v_mod := substring(v_texto FROM 5);
        v_cmd := 'mod';
    ELSIF v_texto LIKE 'modayuda:%' THEN
        v_mod := substring(v_texto FROM 10);
        v_cmd := 'modayuda';
    ELSIF v_texto LIKE 'tipo:%' THEN
        v_tip := substring(v_texto FROM 6);
        v_cmd := 'tipo';
    ELSIF v_texto LIKE 'rec:%' THEN
        -- >>> 064: 'rec:<accion>[:<id>]'. El resto queda entero en `rec` y lo
        -- parte el handler: acá solo se reconoce el prefijo.
        v_rec := substring(v_texto FROM 5);
        v_cmd := 'rec';
    ELSIF v_texto LIKE 'acepto:%' THEN
        -- >>> 051: 'acepto:<mensaje original>' — el consentimiento se lleva
        -- puesto el paso que lo disparó para poder retomarlo.
        v_arg := btrim(substring(v_texto FROM 8));
        v_cmd := 'acepto';
    END IF;

    -- El canal por defecto es telegram; el evento puede declarar otro (044).
    -- Acá también se crea el usuario y su negocio si es la primera vez (050).
    v_usuario_id := usuario_de_canal('telegram', p_evento);
    SELECT negocio_id, autorizacion_datos, rol
      INTO v_negocio_id, v_autoriz, v_rol
    FROM usuarios WHERE id = v_usuario_id;

    -- Solo los de archivos: los de texto no se eligen de una lista.
    SELECT count(*) INTO v_n_serv
    FROM servicios WHERE activo AND entrada = 'archivos';
    SELECT EXISTS (SELECT 1 FROM servicios WHERE activo AND entrada = 'texto'
                     AND codigo = 'consulta') INTO v_consulta;

    RETURN jsonb_build_object(
        'evento',     p_evento,
        'chat_id',    (p_evento #>> '{chat,id}')::bigint,
        'usuario_id', v_usuario_id,
        'negocio_id', v_negocio_id,
        'rol',        v_rol::text,
        'autoriz',    coalesce(v_autoriz, false),
        'texto',      v_texto,
        'cmd',        v_cmd,
        'arg',        v_arg,
        'svc',        v_svc,
        'mod',        v_mod,
        'tip',        v_tip,
        'rec',        v_rec,
        'tiene_doc',  coalesce((p_evento ->> 'tiene_documento')::boolean, false),
        'n_serv',     v_n_serv,
        'consulta',   v_consulta);
END;
$$;

CREATE OR REPLACE FUNCTION router_h_comandos(p_ctx jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_chat_id    bigint  := (p_ctx ->> 'chat_id')::bigint;
    v_usuario_id bigint  := (p_ctx ->> 'usuario_id')::bigint;
    v_negocio_id bigint  := (p_ctx ->> 'negocio_id')::bigint;
    v_texto      text    := p_ctx ->> 'texto';
    v_cmd        text    := p_ctx ->> 'cmd';
    v_arg        text    := coalesce(p_ctx ->> 'arg', '');
    v_svc        text    := p_ctx ->> 'svc';
    v_mod        text    := p_ctx ->> 'mod';
    v_tip        text    := p_ctx ->> 'tip';
    v_autoriz    boolean := (p_ctx ->> 'autoriz')::boolean;
    v_n_serv     int     := (p_ctx ->> 'n_serv')::int;
    v_ses_id     bigint  := (p_ctx ->> 'sesion_id')::bigint;
    v_ses_estado text    := p_ctx ->> 'sesion_estado';
    v_ses_srv    text    := p_ctx ->> 'sesion_servicio';
    v_servicio   record;
    v_modulo     record;
    v_titulo     text;
    v_rec        text    := p_ctx ->> 'rec';   -- >>> 064
    v_rec_acc    text;
    v_rec_id     bigint;
    v_reco       record;
    v_res        jsonb;
BEGIN
    -- ---- Informativos: accesibles incluso sin autorizar --------------------
    IF v_cmd IN ('/start','/help','/ayuda') THEN
        RETURN router_respuesta(v_chat_id, 'sistema.bienvenida');   -- >>> 046
    END IF;
    IF v_cmd = '/comofunciona' THEN
        RETURN router_respuesta(v_chat_id, 'sistema.como_funciona');
    END IF;
    IF v_cmd = '/privacidad' THEN
        RETURN router_respuesta(v_chat_id, 'sistema.privacidad');
    END IF;

    -- ---- Módulos: son un menú, no tocan un solo dato -----------------------
    -- >>> 051: van ANTES del consentimiento a propósito. Mirar la lista de lo
    -- que el asistente sabe hacer no requiere autorizar nada; el permiso se
    -- pide justo cuando se elige una opción, que es cuando se van a entregar
    -- datos del negocio. Pedirlo antes es pedirlo a ciegas.
    IF v_cmd = 'mod' THEN
        SELECT * INTO v_modulo FROM modulos WHERE activo AND codigo = v_mod;
        IF v_modulo.codigo IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.bienvenida');
        END IF;
        RETURN router_respuesta(v_chat_id, 'sistema.modulo',
                 jsonb_build_object('titular', v_modulo.titular),
                 teclado_modulo(v_modulo.codigo));
    END IF;

    IF v_cmd = 'modayuda' THEN
        SELECT * INTO v_modulo FROM modulos WHERE activo AND codigo = v_mod;
        IF v_modulo.codigo IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.bienvenida');
        END IF;
        RETURN router_respuesta(v_chat_id, 'sistema.modulo_ayuda',
                 jsonb_build_object('ayuda', v_modulo.ayuda),
                 teclado_modulo(v_modulo.codigo));
    END IF;

    -- ---- >>> 051: "Acepto" con memoria de lo que se estaba haciendo --------
    -- El botón del consentimiento manda 'acepto:<lo que el usuario había
    -- tocado>'. Se registra el permiso y se vuelve a despachar ESE mensaje, ya
    -- autorizado: el usuario cae exactamente donde iba, no en la bienvenida.
    -- No hay recursión infinita porque la autorización ya quedó en true.
    IF v_cmd = 'acepto' OR
       (NOT v_autoriz AND lower(v_texto) IN ('acepto','autorizo','si','sí','ok','dale')) THEN
        UPDATE usuarios SET autorizacion_datos = true, autorizacion_fecha = now()
        WHERE id = v_usuario_id;
        IF v_cmd = 'acepto' AND v_arg <> '' THEN
            RETURN router_procesar_mensaje(
                     (p_ctx -> 'evento') || jsonb_build_object('texto', v_arg));
        END IF;
        RETURN router_respuesta(v_chat_id, 'sistema.bienvenida');
    END IF;

    -- ---- Consentimiento de datos (una sola vez) ----------------------------
    -- Lo que el usuario tocó viaja en el botón para poder retomarlo al aceptar.
    IF NOT v_autoriz THEN
        RETURN router_respuesta(v_chat_id, 'sistema.consentimiento',
                 jsonb_build_object('meses',
                   coalesce((parametro(NULL, 'plan_free_meses_historia'))::text, '3')),
                 teclado_consentimiento(v_texto));
    END IF;

    -- ---- >>> 046: naturaleza del negocio -----------------------------------
    -- Se contesta una vez y sigue el camino que estaba interrumpido. Un botón
    -- viejo del historial vuelve a guardar lo mismo: es idempotente.
    IF v_cmd = 'tipo' THEN
        IF v_negocio_id IS NULL
           OR NOT EXISTS (SELECT 1 FROM tipos_negocio WHERE activo AND codigo = v_tip) THEN
            RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
        END IF;
        UPDATE negocios SET tipo = v_tip WHERE id = v_negocio_id;

        IF v_ses_id IS NOT NULL AND v_ses_srv IS NOT NULL THEN
            RETURN router_arranque_servicio(v_negocio_id, v_chat_id, v_ses_srv);
        END IF;
        RETURN router_respuesta(v_chat_id, 'sistema.bienvenida');
    END IF;

    -- ---- >>> 064: acciones sobre una recomendación -------------------------
    -- Va DESPUÉS del consentimiento a propósito: acá se muestran cifras del
    -- negocio, así que exige autorización como todo lo que entrega datos.
    IF v_cmd = 'rec' THEN
        v_rec_acc := split_part(v_rec, ':', 1);
        v_rec_id  := nullif(split_part(v_rec, ':', 2), '')::bigint;

        IF v_negocio_id IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
        END IF;

        IF v_rec_acc = 'list' THEN
            IF NOT EXISTS (SELECT 1 FROM recomendaciones
                            WHERE negocio_id = v_negocio_id
                              AND estado IN ('nueva','vigente')) THEN
                RETURN router_respuesta(v_chat_id, 'recomendacion.sin_pendientes');
            END IF;
            RETURN router_respuesta(v_chat_id, 'recomendacion.lista', '{}'::jsonb,
                     teclado_recomendaciones(v_negocio_id));
        END IF;

        IF v_rec_id IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
        END IF;

        IF v_rec_acc = 'ver' THEN
            SELECT * INTO v_reco FROM recomendaciones
            WHERE id = v_rec_id AND negocio_id = v_negocio_id
              AND estado IN ('nueva','vigente');
            IF v_reco.id IS NULL THEN
                RETURN router_respuesta(v_chat_id, 'recomendacion.no_encontrada');
            END IF;
            RETURN router_respuesta(v_chat_id, 'recomendacion.detalle',
                     jsonb_build_object(
                       'icono', coalesce(v_reco.icono, '🔎'),
                       'titulo', v_reco.titulo,
                       'problema', coalesce(v_reco.problema, ''),
                       'impacto', coalesce(v_reco.impacto, ''),
                       'dias', (current_date - v_reco.detectada_en::date)),
                     teclado_recomendacion(v_rec_id));
        END IF;

        IF v_rec_acc IN ('hice','no_aplica','precio') THEN
            v_res := recomendacion_accion(v_rec_id, v_negocio_id, v_rec_acc,
                                          v_usuario_id);
            IF coalesce((v_res ->> 'ok')::boolean, false) = false THEN
                RETURN router_respuesta(v_chat_id,
                         CASE v_res ->> 'error' WHEN 'sin_precio'
                              THEN 'recomendacion.sin_precio'
                              ELSE 'recomendacion.no_encontrada' END);
            END IF;
            RETURN router_respuesta(v_chat_id,
                     CASE v_rec_acc WHEN 'hice'   THEN 'recomendacion.hecha'
                                    WHEN 'precio' THEN 'recomendacion.precio_aplicado'
                                    ELSE 'recomendacion.ignorada' END,
                     jsonb_build_object('titulo', v_res ->> 'titulo',
                                        'precio', coalesce(v_res ->> 'precio', '')),
                     teclado_recomendaciones(v_negocio_id));
        END IF;

        RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
    END IF;

    -- ---- /portal: el enlace de un solo uso ---------------------------------
    IF v_cmd IN ('/portal','/web') THEN
        RETURN router_portal(v_usuario_id, v_chat_id);
    END IF;

    -- Plan, consumo del mes y enlace de pago si el operador lo configuró.
    IF v_cmd = '/plan' THEN
        RETURN router_plan(v_negocio_id, v_chat_id);
    END IF;

    -- ---- /saber: el dueño le enseña algo al bot ----------------------------
    IF v_cmd = '/saber' THEN
        IF v_negocio_id IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
        END IF;
        IF v_arg = '' THEN
            RETURN router_respuesta(v_chat_id, 'conocimiento.saber_vacio');
        END IF;
        v_titulo := btrim(split_part(v_arg, '.', 1));
        IF char_length(v_titulo) > 80 OR v_titulo = '' THEN
            v_titulo := btrim(left(v_arg, 80));
        END IF;
        PERFORM conocimiento_guardar(v_negocio_id, 'faq', v_titulo, v_arg,
                                     NULL, '{}'::jsonb, 'chat', v_usuario_id);
        RETURN router_respuesta(v_chat_id, 'conocimiento.guardado',
                 jsonb_build_object('titulo', v_titulo));
    END IF;

    -- ---- Cancelar ----------------------------------------------------------
    IF v_cmd IN ('/cancelar','/cancel') THEN
        IF v_ses_id IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.sin_sesion');
        END IF;
        UPDATE sesiones SET estado = 'expirada', cerrada_en = now()
        WHERE usuario_id = v_usuario_id AND cerrada_en IS NULL;
        RETURN router_respuesta(v_chat_id, 'sesion.cancelada');
    END IF;

    -- ---- /nueva ------------------------------------------------------------
    IF v_cmd = '/nueva' THEN
        UPDATE sesiones SET estado = 'expirada', cerrada_en = now()
        WHERE usuario_id = v_usuario_id AND cerrada_en IS NULL;

        IF v_n_serv = 1 THEN
            SELECT * INTO v_servicio FROM servicios
            WHERE activo AND entrada = 'archivos' LIMIT 1;
            INSERT INTO sesiones (usuario_id, negocio_id, servicio_codigo, estado, paso)
            VALUES (v_usuario_id, v_negocio_id, v_servicio.codigo, 'recibiendo', 'cargar_archivos');
            RETURN router_arranque_servicio(v_negocio_id, v_chat_id, v_servicio.codigo);
        END IF;

        INSERT INTO sesiones (usuario_id, negocio_id, estado, paso)
        VALUES (v_usuario_id, v_negocio_id, 'intake', 'elegir_servicio');
        RETURN router_respuesta(v_chat_id, 'sistema.elegir_servicio',
                 '{}'::jsonb, teclado_intake());
    END IF;

    -- ---- Servicio elegido desde el menú (045) ------------------------------
    IF v_cmd = 'svc' AND (v_ses_id IS NULL OR v_ses_estado = 'intake') THEN
        SELECT * INTO v_servicio FROM servicios
        WHERE activo AND entrada = 'archivos' AND codigo = v_svc;

        IF v_servicio.codigo IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.servicio_no_reconocido',
                     '{}'::jsonb, teclado_intake());
        END IF;

        IF v_ses_id IS NULL THEN
            INSERT INTO sesiones (usuario_id, negocio_id, servicio_codigo, estado, paso)
            VALUES (v_usuario_id, v_negocio_id, v_servicio.codigo,
                    'recibiendo', 'cargar_archivos');
        ELSE
            UPDATE sesiones SET servicio_codigo = v_servicio.codigo,
                   estado = 'recibiendo', paso = 'cargar_archivos'
            WHERE id = v_ses_id;
        END IF;

        RETURN router_arranque_servicio(v_negocio_id, v_chat_id, v_servicio.codigo);
    END IF;

    RETURN NULL;   -- no me toca: que decida el estado de la sesión
END;
$$;


-- El accesor que consume el portal necesita el icono y los datos accionables:
-- sin `datos` no puede saber si ofrecer el botón de aplicar precio.
CREATE OR REPLACE FUNCTION recomendaciones_vigentes(p_negocio_id bigint,
                                                    p_limite int DEFAULT 20)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'id', id, 'regla', regla, 'clave_objeto', clave_objeto,
             'icono', icono,
             'titulo', titulo, 'problema', problema, 'impacto', impacto,
             'impacto_mes', impacto_mes, 'impacto_tipo', impacto_tipo,
             'prioridad', prioridad, 'opciones', opciones,
             'datos', coalesce(datos, '{}'::jsonb),
             'origen_stock', origen_stock, 'estado', estado,
             'detectada_en', detectada_en, 'veces_vista', veces_vista,
             -- Cuántos periodos lleva sin resolverse. Es la diferencia entre
             -- "te lo digo por primera vez" y "van cuatro veces".
             'dias_abierta', (current_date - detectada_en::date))
             ORDER BY CASE prioridad WHEN 'alta' THEN 1 WHEN 'media' THEN 2 ELSE 3 END,
                      impacto_mes DESC), '[]'::jsonb)
    FROM (SELECT * FROM recomendaciones
           WHERE negocio_id = p_negocio_id AND estado IN ('nueva','vigente')
           ORDER BY CASE prioridad WHEN 'alta' THEN 1 WHEN 'media' THEN 2 ELSE 3 END,
                    impacto_mes DESC
           LIMIT p_limite) r;
$$;

-- =============================================================================
-- 6. Las mismas tres acciones desde el portal
-- =============================================================================
-- No hay una segunda implementación: la RPC valida el negocio de la sesión y
-- delega en `recomendacion_accion`, igual que el chat. Un solo punto de
-- escritura para los dos canales.
CREATE OR REPLACE FUNCTION portal_recomendacion_accion(p_id bigint, p_accion text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
BEGIN
    RETURN recomendacion_accion(p_id, portal_negocio(), p_accion, NULL);
END;
$$;

GRANT EXECUTE ON FUNCTION portal_recomendacion_accion(bigint, text) TO portal_usuario;

NOTIFY pgrst, 'reload schema';
