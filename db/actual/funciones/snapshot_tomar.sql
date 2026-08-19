CREATE OR REPLACE FUNCTION public.snapshot_tomar(p_negocio_id bigint, p_origen text DEFAULT 'manual'::text, p_ejecucion_id bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_desde    date;
    v_hasta    date;
    v_meses    numeric;
    v_metricas jsonb;
    v_id       bigint;
BEGIN
    SELECT min(fecha), max(fecha) INTO v_desde, v_hasta
    FROM mov_visibles WHERE negocio_id = p_negocio_id AND fecha IS NOT NULL;

    -- Sin un solo movimiento fechado no hay estado que fotografiar. Devolver
    -- NULL en vez de una fila vacía: un snapshot de la nada haría creer a B3
    -- que hubo un periodo medido en el que todo valía cero.
    IF v_desde IS NULL THEN
        RETURN NULL;
    END IF;

    -- La misma ventana con la que `recomendaciones_negocio` escala lo mensual.
    v_meses := greatest((v_hasta - v_desde)::numeric / 30.0, 1);

    SELECT jsonb_build_object(
      -- --- Totales del periodo ------------------------------------------------
      'totales', (SELECT jsonb_build_object(
                    'ventas',   round(coalesce(sum(valor_total) FILTER (WHERE tipo = 'venta'), 0)),
                    'compras',  round(coalesce(sum(valor_total) FILTER (WHERE tipo = 'compra'), 0)),
                    'movimientos_venta',  count(*) FILTER (WHERE tipo = 'venta'),
                    'movimientos_compra', count(*) FILTER (WHERE tipo = 'compra'),
                    'meses', round(v_meses, 2),
                    -- Lo que mueve el negocio en un mes: es el denominador con
                    -- el que se priorizan las recomendaciones, así que sin él un
                    -- impacto de dos snapshots distintos no es comparable.
                    'base_mes', round(greatest(
                        coalesce(sum(valor_total) FILTER (WHERE tipo = 'venta'),
                                 sum(valor_total) FILTER (WHERE tipo = 'compra'), 0) / v_meses, 1)))
                  FROM mov_visibles WHERE negocio_id = p_negocio_id),

      -- --- Resumen de catálogo ------------------------------------------------
      'productos', (SELECT jsonb_build_object(
                      'total', count(*),
                      'con_precio', count(*) FILTER (WHERE precio_actual IS NOT NULL),
                      'margen_promedio_pct', round(avg(margen_pct), 2))
                    FROM v_margen_producto WHERE negocio_id = p_negocio_id),

      -- --- Margen por producto (TODOS, no solo los que disparan regla) --------
      -- Guardar solo los de margen bajo sería guardar el informe otra vez. Para
      -- ver un deterioro hay que tener también los que hoy están bien.
      'margenes', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                     'producto_id', producto_id, 'nombre', nombre_canonico,
                     'costo', costo_actual, 'precio', precio_actual,
                     'margen_pct', margen_pct) ORDER BY producto_id), '[]'::jsonb)
                   FROM v_margen_producto WHERE negocio_id = p_negocio_id),

      -- --- Cobertura y stock por producto -------------------------------------
      'coberturas', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                       'producto_id', r.producto_id, 'nombre', p.nombre_canonico,
                       'dias_cobertura', r.dias_cobertura,
                       'unidades_por_dia', r.unidades_por_dia,
                       'balance', b.balance,
                       -- 054: sin esto, comparar dos coberturas puede ser
                       -- comparar un conteo real contra una estimación.
                       'origen_stock', r.origen_stock) ORDER BY r.producto_id), '[]'::jsonb)
                     FROM v_rotacion_producto r
                     JOIN productos p ON p.id = r.producto_id
                     LEFT JOIN v_balance_unidades b
                            ON b.producto_id = r.producto_id AND b.negocio_id = r.negocio_id
                     WHERE r.negocio_id = p_negocio_id),

      -- --- Deriva de costo ----------------------------------------------------
      'derivas', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                    'producto_id', producto_id, 'costo_ini', costo_ini,
                    'costo_fin', costo_fin, 'deriva_pct', deriva_pct)
                    ORDER BY producto_id), '[]'::jsonb)
                  FROM v_deriva_costo WHERE negocio_id = p_negocio_id),

      -- --- Gasto por proveedor ------------------------------------------------
      -- El % va calculado y no derivado al leer: si mañana entra una compra
      -- vieja, el gasto total del periodo cambia, y el snapshot tiene que
      -- seguir diciendo qué concentración se midió ESE día.
      'proveedores', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'proveedor', prov, 'gasto', round(gasto), 'pct', pct)
                        ORDER BY gasto DESC), '[]'::jsonb)
                      FROM (SELECT prov, gasto,
                                   round(gasto * 100.0 / nullif(sum(gasto) OVER (), 0), 1) AS pct
                            FROM (SELECT nullif(btrim(coalesce(raw ->> 'proveedor','')),'') AS prov,
                                         sum(valor_total) AS gasto
                                  FROM mov_visibles
                                  WHERE negocio_id = p_negocio_id AND tipo = 'compra'
                                    AND nullif(btrim(coalesce(raw ->> 'proveedor','')),'') IS NOT NULL
                                  GROUP BY 1) g0) g),

      -- --- Precio pagado por producto y proveedor -----------------------------
      -- Es lo que hace posible "este proveedor te subió tres veces en el año".
      -- Sin el par (producto, proveedor) solo se ve el gasto agregado, que sube
      -- también cuando simplemente comprás más.
      'precios_proveedor', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                              'producto_id', producto_id, 'proveedor', prov,
                              'precio_prom', round(precio_prom, 2), 'unidades', u)
                              ORDER BY producto_id, prov), '[]'::jsonb)
                            FROM (SELECT producto_id,
                                         nullif(btrim(coalesce(raw ->> 'proveedor','')),'') AS prov,
                                         sum(cantidad) AS u,
                                         sum(valor_total) / nullif(sum(cantidad), 0) AS precio_prom
                                  FROM mov_visibles
                                  WHERE negocio_id = p_negocio_id AND tipo = 'compra'
                                    AND producto_id IS NOT NULL AND cantidad > 0
                                    AND nullif(btrim(coalesce(raw ->> 'proveedor','')),'') IS NOT NULL
                                  GROUP BY 1, 2) pp),

      -- --- Unidades vendidas por producto -------------------------------------
      -- Para "este producto dejó de venderse", que se detecta comparando contra
      -- un snapshot anterior donde sí figuraba.
      'ventas_producto', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                            'producto_id', producto_id, 'unidades', round(u, 3),
                            'importe', round(imp)) ORDER BY producto_id), '[]'::jsonb)
                          FROM (SELECT producto_id, sum(cantidad) AS u, sum(valor_total) AS imp
                                FROM mov_visibles
                                WHERE negocio_id = p_negocio_id AND tipo = 'venta'
                                  AND producto_id IS NOT NULL
                                GROUP BY 1) vp),

      -- --- Concentración de utilidad ------------------------------------------
      'pareto', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                   'producto_id', producto_id, 'utilidad', round(utilidad),
                   'pct_utilidad', pct_utilidad, 'pct_acumulado', pct_acumulado)
                   ORDER BY utilidad DESC), '[]'::jsonb)
                 FROM v_pareto_utilidad WHERE negocio_id = p_negocio_id),

      -- --- Calidad del dato sobre el que se midió todo esto -------------------
      -- Un snapshot con el 40% de la plata sin producto resuelto (057) no es
      -- comparable con uno limpio, y quien compare tiene que poder saberlo.
      'calidad', (SELECT jsonb_build_object(
                    'movs_sin_producto', movs_sin_producto,
                    'dinero_sin_producto', dinero_sin_producto,
                    'pct_dinero_fuera', coalesce(pct_dinero_fuera, 0),
                    'productos_stock_estimado', (
                      SELECT count(*) FROM v_balance_unidades
                       WHERE negocio_id = p_negocio_id AND origen_stock = 'estimado'))
                  FROM v_calidad_matching WHERE negocio_id = p_negocio_id),

      -- --- Con qué umbrales se midió ------------------------------------------
      -- Los umbrales son por negocio y se pueden cambiar. Una nota de salud que
      -- baja porque alguien movió `margen_minimo_pct` no es un deterioro del
      -- negocio, y sin esto no habría forma de distinguirlo.
      'umbrales', snapshot_umbrales(p_negocio_id)
    ) INTO v_metricas;

    INSERT INTO snapshots_negocio (negocio_id, fecha, version, periodo, salud,
                                   metricas, origen, ejecucion_id)
    VALUES (p_negocio_id, current_date, snapshot_version(),
            daterange(v_desde, v_hasta, '[]'),
            salud_negocio(p_negocio_id), v_metricas, p_origen, p_ejecucion_id)
    ON CONFLICT ON CONSTRAINT uq_snapshot_dia DO UPDATE
      SET version = EXCLUDED.version, periodo = EXCLUDED.periodo,
          salud = EXCLUDED.salud, metricas = EXCLUDED.metricas,
          origen = EXCLUDED.origen, ejecucion_id = EXCLUDED.ejecucion_id,
          creado_en = now()
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$function$
