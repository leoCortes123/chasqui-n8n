CREATE OR REPLACE FUNCTION public.hallazgos_compras(p_negocio_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_deriva_ali numeric := (parametro(p_negocio_id, 'deriva_costo_alerta_pct'))::text::numeric;
    v_out jsonb;
BEGIN
    WITH compras AS (
        SELECT m.*, coalesce(p.nombre_canonico, m.raw ->> 'descripcion',
                             m.raw ->> 'producto', 'sin nombre') AS etiqueta,
               nullif(btrim(coalesce(m.raw ->> 'proveedor', '')), '') AS proveedor
        FROM mov_visibles m
        LEFT JOIN productos p ON p.id = m.producto_id
        WHERE m.negocio_id = p_negocio_id AND m.tipo = 'compra'
    ),
    gasto AS (SELECT sum(valor_total) AS total FROM compras)
    SELECT jsonb_build_object(
      'negocio_id', p_negocio_id,
      'generado_en', now(),

      'periodo', (SELECT jsonb_build_object(
                    'desde', min(fecha), 'hasta', max(fecha),
                    'movimientos_compra', count(*))
                  FROM compras WHERE fecha IS NOT NULL),

      'resumen', (SELECT jsonb_build_object(
                    'productos',   count(DISTINCT etiqueta),
                    'gasto_total', round(coalesce(sum(valor_total), 0)),
                    'proveedores', count(DISTINCT proveedor) FILTER (WHERE proveedor IS NOT NULL),
                    'documentos',  count(DISTINCT documento_id))
                  FROM compras),

      -- Dónde se va la plata: top de gasto por producto con su participación.
      'gasto_producto', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                           'producto', etiqueta, 'gasto', gasto_p,
                           'unidades', unidades, 'pct_gasto', pct) ORDER BY gasto_p DESC), '[]')
                         FROM (SELECT etiqueta,
                                      round(sum(valor_total)) AS gasto_p,
                                      round(sum(cantidad))    AS unidades,
                                      round((sum(valor_total) * 100.0
                                             / nullif((SELECT total FROM gasto), 0))::numeric, 1) AS pct
                               FROM compras GROUP BY etiqueta
                               ORDER BY sum(valor_total) DESC NULLS LAST LIMIT 8) t),

      -- Costo al alza: misma vista y mismo umbral que el análisis de ventas.
      'deriva_costo', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                         'producto_id', d.producto_id, 'producto', p.nombre_canonico,
                         'costo_ini', d.costo_ini, 'costo_fin', d.costo_fin,
                         'deriva_pct', d.deriva_pct) ORDER BY abs(d.deriva_pct) DESC), '[]')
                       FROM v_deriva_costo d JOIN productos p ON p.id = d.producto_id
                       WHERE d.negocio_id = p_negocio_id
                         AND abs(d.deriva_pct) >= v_deriva_ali),

      -- Precios muy distintos por el mismo producto: margen para negociar.
      'precio_disperso', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                            'producto', etiqueta, 'precio_min', pmin,
                            'precio_max', pmax, 'dispersion_pct', disp)
                            ORDER BY disp DESC), '[]')
                          FROM (SELECT etiqueta,
                                       round(min(valor_unitario)) AS pmin,
                                       round(max(valor_unitario)) AS pmax,
                                       round(((max(valor_unitario) - min(valor_unitario))
                                              / nullif(min(valor_unitario), 0) * 100)::numeric, 1) AS disp
                                FROM compras WHERE valor_unitario > 0
                                GROUP BY etiqueta
                                HAVING count(*) > 1
                                   AND (max(valor_unitario) - min(valor_unitario))
                                       / nullif(min(valor_unitario), 0) >= 0.10
                                ORDER BY disp DESC LIMIT 8) t),

      -- Peso de cada proveedor en el gasto.
      'proveedores', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'proveedor', coalesce(proveedor, 'sin dato'),
                        'gasto', gasto_v, 'pct_gasto', pct) ORDER BY gasto_v DESC), '[]')
                      FROM (SELECT proveedor, round(sum(valor_total)) AS gasto_v,
                                   round((sum(valor_total) * 100.0
                                          / nullif((SELECT total FROM gasto), 0))::numeric, 1) AS pct
                            FROM compras GROUP BY proveedor
                            ORDER BY sum(valor_total) DESC NULLS LAST LIMIT 6) t),

      -- Comprado que no registra ni una venta: plata quieta. Solo tiene sentido
      -- si el negocio también carga ventas; si no hay ventas, va vacío y el
      -- prompt no arma la sección.
      'sin_venta', CASE WHEN EXISTS (SELECT 1 FROM mov_visibles
                                     WHERE negocio_id = p_negocio_id AND tipo = 'venta')
                   THEN (SELECT coalesce(jsonb_agg(jsonb_build_object(
                           'producto', etiqueta, 'unidades', unidades, 'gasto', gasto_p)
                           ORDER BY gasto_p DESC), '[]')
                         FROM (SELECT c.etiqueta, round(sum(c.cantidad)) AS unidades,
                                      round(sum(c.valor_total)) AS gasto_p
                               FROM compras c
                               WHERE c.producto_id IS NOT NULL
                                 AND NOT EXISTS (SELECT 1 FROM mov_visibles v
                                                 WHERE v.negocio_id = p_negocio_id
                                                   AND v.tipo = 'venta'
                                                   AND v.producto_id = c.producto_id)
                               GROUP BY c.etiqueta
                               ORDER BY sum(c.valor_total) DESC LIMIT 8) t)
                   ELSE '[]'::jsonb END
    ) INTO v_out;

    RETURN v_out;
END;
$function$
