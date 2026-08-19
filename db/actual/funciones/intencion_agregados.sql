CREATE OR REPLACE FUNCTION public.intencion_agregados(p_negocio_id bigint, p_metrica text, p_desde date, p_hasta date, p_producto bigint DEFAULT NULL::bigint, p_proveedor text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_tipo tipo_movimiento;
    v_out  jsonb;
BEGIN
    IF p_metrica IN ('ventas','compras') THEN
        v_tipo := CASE p_metrica WHEN 'ventas' THEN 'venta' ELSE 'compra' END::tipo_movimiento;

        SELECT jsonb_build_object(
                 'total', round(coalesce(sum(valor_total), 0)),
                 -- La misma cifra ya escrita como se escribe en Colombia. Sin
                 -- esto el modelo entrega "68400" y queda a que se le ocurra
                 -- formatearlo — y si lo formatea por su cuenta, es una cifra
                 -- que no está en el contexto y `validar_cifras` la rechaza.
                 'total_txt', '$' || miles(round(coalesce(sum(valor_total), 0))),
                 'movimientos', count(*),
                 'unidades', round(coalesce(sum(cantidad), 0), 2),
                 'por_mes', coalesce((
                    SELECT jsonb_agg(jsonb_build_object(
                             'mes', to_char(mes, 'YYYY-MM'), 'total', round(t))
                             ORDER BY mes)
                    FROM (SELECT date_trunc('month', m.fecha) AS mes, sum(m.valor_total) AS t
                          FROM mov_visibles m
                          WHERE m.negocio_id = p_negocio_id AND m.tipo = v_tipo
                            AND (p_desde IS NULL OR m.fecha >= p_desde)
                            AND (p_hasta IS NULL OR m.fecha <= p_hasta)
                            AND (p_producto IS NULL OR m.producto_id = p_producto)
                            AND (p_proveedor IS NULL
                                 OR btrim(coalesce(m.raw ->> 'proveedor','')) = p_proveedor)
                          GROUP BY 1) s), '[]'::jsonb),
                 'top_productos', coalesce((
                    SELECT jsonb_agg(jsonb_build_object(
                             'producto', nom, 'total', round(t),
                             'total_txt', '$' || miles(round(t)),
                             'unidades', round(u, 2))
                             ORDER BY t DESC)
                    FROM (SELECT p.nombre_canonico AS nom, sum(m.valor_total) AS t,
                                 sum(m.cantidad) AS u
                          FROM mov_visibles m JOIN productos p ON p.id = m.producto_id
                          WHERE m.negocio_id = p_negocio_id AND m.tipo = v_tipo
                            AND (p_desde IS NULL OR m.fecha >= p_desde)
                            AND (p_hasta IS NULL OR m.fecha <= p_hasta)
                            AND (p_producto IS NULL OR m.producto_id = p_producto)
                            AND (p_proveedor IS NULL
                                 OR btrim(coalesce(m.raw ->> 'proveedor','')) = p_proveedor)
                          GROUP BY 1 ORDER BY 2 DESC LIMIT 8) s), '[]'::jsonb))
          INTO v_out
        FROM mov_visibles m
        WHERE m.negocio_id = p_negocio_id AND m.tipo = v_tipo
          AND (p_desde IS NULL OR m.fecha >= p_desde)
          AND (p_hasta IS NULL OR m.fecha <= p_hasta)
          AND (p_producto IS NULL OR m.producto_id = p_producto)
          AND (p_proveedor IS NULL
               OR btrim(coalesce(m.raw ->> 'proveedor','')) = p_proveedor);

    ELSIF p_metrica = 'gasto_proveedor' THEN
        SELECT jsonb_build_object(
                 'total', round(coalesce(sum(gasto), 0)),
                 'total_txt', '$' || miles(round(coalesce(sum(gasto), 0))),
                 'proveedores', coalesce(jsonb_agg(jsonb_build_object(
                    'proveedor', prov, 'gasto', round(gasto),
                    'gasto_txt', '$' || miles(round(gasto)),
                    'pct', round(gasto * 100.0 / nullif(sum(gasto) OVER (), 0), 1))
                    ORDER BY gasto DESC), '[]'::jsonb))
          INTO v_out
        FROM (SELECT nullif(btrim(coalesce(raw ->> 'proveedor','')),'') AS prov,
                     sum(valor_total) AS gasto
              FROM mov_visibles
              WHERE negocio_id = p_negocio_id AND tipo = 'compra'
                AND (p_desde IS NULL OR fecha >= p_desde)
                AND (p_hasta IS NULL OR fecha <= p_hasta)
                AND nullif(btrim(coalesce(raw ->> 'proveedor','')),'') IS NOT NULL
              GROUP BY 1) g;

    ELSIF p_metrica = 'margen' THEN
        -- Sin ventana: el margen es del estado actual, no de un periodo. Se
        -- ordena de peor a mejor porque la pregunta casi siempre es "¿cuál me
        -- deja poco?", no "¿cuál me deja bien?".
        SELECT jsonb_build_object(
                 'margen_mediano_pct', round(percentile_cont(0.5)
                     WITHIN GROUP (ORDER BY margen_pct)::numeric, 2),
                 'productos', coalesce(jsonb_agg(jsonb_build_object(
                    'producto', nombre_canonico, 'costo', costo_actual,
                    'precio', precio_actual, 'margen_pct', margen_pct)
                    ORDER BY margen_pct), '[]'::jsonb))
          INTO v_out
        FROM v_margen_producto
        WHERE negocio_id = p_negocio_id AND margen_pct IS NOT NULL
          AND (p_producto IS NULL OR producto_id = p_producto);

    ELSIF p_metrica = 'costo' THEN
        SELECT jsonb_build_object(
                 'productos', coalesce(jsonb_agg(jsonb_build_object(
                    'producto', p.nombre_canonico, 'costo_ini', d.costo_ini,
                    'costo_fin', d.costo_fin, 'deriva_pct', d.deriva_pct)
                    ORDER BY d.deriva_pct DESC), '[]'::jsonb))
          INTO v_out
        FROM v_deriva_costo d JOIN productos p ON p.id = d.producto_id
        WHERE d.negocio_id = p_negocio_id
          AND (p_producto IS NULL OR d.producto_id = p_producto);

    ELSIF p_metrica = 'cobertura' THEN
        SELECT jsonb_build_object(
                 'productos', coalesce(jsonb_agg(jsonb_build_object(
                    'producto', p.nombre_canonico,
                    'dias_cobertura', r.dias_cobertura,
                    'unidades_por_dia', r.unidades_por_dia,
                    'stock', b.balance,
                    -- 054: el origen del stock viaja siempre. Responder "te
                    -- quedan 40" sobre una estimación sin decirlo sería
                    -- exactamente lo que A2 vino a arreglar.
                    'origen_stock', r.origen_stock)
                    ORDER BY r.dias_cobertura), '[]'::jsonb))
          INTO v_out
        FROM v_rotacion_producto r
        JOIN productos p ON p.id = r.producto_id
        LEFT JOIN v_balance_unidades b
               ON b.producto_id = r.producto_id AND b.negocio_id = r.negocio_id
        WHERE r.negocio_id = p_negocio_id
          AND (p_producto IS NULL OR r.producto_id = p_producto);

    ELSIF p_metrica = 'utilidad' THEN
        SELECT jsonb_build_object(
                 'productos', coalesce(jsonb_agg(jsonb_build_object(
                    'producto', p.nombre_canonico, 'utilidad', round(pa.utilidad),
                    'utilidad_txt', '$' || miles(round(pa.utilidad)),
                    'pct_utilidad', pa.pct_utilidad,
                    'pct_acumulado', pa.pct_acumulado)
                    ORDER BY pa.utilidad DESC), '[]'::jsonb))
          INTO v_out
        FROM v_pareto_utilidad pa JOIN productos p ON p.id = pa.producto_id
        WHERE pa.negocio_id = p_negocio_id
          AND (p_producto IS NULL OR pa.producto_id = p_producto);
    END IF;

    RETURN coalesce(v_out, '{}'::jsonb);
END;
$function$
