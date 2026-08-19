CREATE OR REPLACE FUNCTION public.recomendaciones_negocio(p_negocio_id bigint, p_registro boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
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
    -- >>> 069: cartera.
    v_mora_dias    numeric := coalesce((parametro(p_negocio_id,'cartera_mora_dias'))::text::numeric, 15);
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

    -- R11. Te deben y ya se pasaron de la fecha -----------------------------
    -- La cartera existía desde la 036 como pieza de ERP: datos que se cargaban
    -- y se miraban en una pestaña. Acá pasa a ser lo que justifica su
    -- existencia dentro de este producto — una señal de LIQUIDEZ, con impacto
    -- de tipo `capital`: no es plata que se pierde, es plata que es tuya y no
    -- está. Exactamente el mismo caso que "plata quieta", y por eso comparte
    -- umbral y tratamiento.
    -- El impacto es el saldo VENCIDO, no el total que ese cliente debe. No es un
    -- detalle: un cliente que debe $10.000.000 con $100.000 en mora tendría un
    -- impacto cien veces mayor del real y encabezaría el informe por encima de
    -- problemas que sí cuestan plata. `v_cartera_tercero` no separa las dos
    -- cosas, así que la cuenta se hace acá.
    cartera_mora AS (
        SELECT f.tercero_id, t.nombre,
               sum(f.saldo) AS saldo_total,
               sum(f.saldo) FILTER (
                 WHERE f.vencimiento IS NOT NULL
                   AND f.vencimiento < current_date)        AS saldo_vencido,
               count(*) FILTER (
                 WHERE f.vencimiento IS NOT NULL
                   AND f.vencimiento < current_date)        AS facturas_vencidas,
               max(current_date - f.vencimiento) FILTER (
                 WHERE f.vencimiento < current_date)        AS dias_mora
        FROM facturas f
        JOIN terceros t ON t.id = f.tercero_id
        WHERE f.negocio_id = p_negocio_id
          AND f.tipo = 'venta'          -- lo que te deben, no lo que debés
          AND f.saldo > 0
        GROUP BY 1, 2
    ),
    r_cartera AS (
        SELECT 'cartera' AS regla, ('tercero:' || c.tercero_id) AS clave_objeto,
               '💵' AS icono, c.nombre AS titulo,
               round(c.saldo_vencido) AS impacto_mes,
               'capital'::text AS impacto_tipo,
               format('Son $%s tuyos que ya se pasaron de fecha.',
                      miles(round(c.saldo_vencido))) AS impacto_txt,
               format('%s te debe $%s vencidos en %s factura%s, y la más vieja lleva %s días.',
                      c.nombre, miles(round(c.saldo_vencido)), c.facturas_vencidas,
                      CASE WHEN c.facturas_vencidas = 1 THEN '' ELSE 's' END,
                      c.dias_mora)
               -- Si además hay saldo por vencer se dice, pero aparte: mezclarlo
               -- con lo vencido es lo que infla la cifra.
               || CASE WHEN c.saldo_total > c.saldo_vencido
                       THEN format(' Te debe otros $%s que todavía no se vencen.',
                                   miles(round(c.saldo_total - c.saldo_vencido)))
                       ELSE '' END AS problema,
               jsonb_build_array(
                 format('Llamá a %s esta semana: cuanto más vieja la factura, más cuesta cobrarla.', c.nombre),
                 'Si ya te pagó, registralo en el portal para que deje de aparecer acá.') AS opciones,
               NULL::text AS origen_stock,
               jsonb_build_object('tercero_id', c.tercero_id,
                                  'saldo_vencido', round(c.saldo_vencido),
                                  'saldo_total', round(c.saldo_total),
                                  'dias_mora', c.dias_mora) AS datos
        FROM cartera_mora c
        WHERE c.dias_mora IS NOT NULL
          AND c.dias_mora >= v_mora_dias
          AND c.saldo_vencido > 0
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
        SELECT * FROM r_vs_ano      UNION ALL
        -- >>> 069: la cartera como señal de liquidez.
        SELECT * FROM r_cartera
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
$function$
