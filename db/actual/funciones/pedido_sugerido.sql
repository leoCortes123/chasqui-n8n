CREATE OR REPLACE FUNCTION public.pedido_sugerido(p_negocio_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_items jsonb;
    v_total numeric;
    v_sin   int;
BEGIN
    SELECT coalesce(jsonb_agg(x ORDER BY (x ->> 'costo')::numeric DESC NULLS LAST),
                    '[]'::jsonb),
           coalesce(sum((x ->> 'costo')::numeric), 0),
           count(*) FILTER (WHERE x ->> 'proveedor' IS NULL)
      INTO v_items, v_total, v_sin
    FROM (
        SELECT jsonb_strip_nulls(jsonb_build_object(
                 'recomendacion_id', r.id,
                 'producto', r.titulo,
                 'unidades', u.n,
                 'unidades_txt', unidades_es(u.n),
                 'proveedor', pb.proveedor,
                 'precio_unitario', pb.precio,
                 'costo', CASE WHEN pb.precio IS NOT NULL
                               THEN round(u.n * pb.precio) END,
                 'costo_txt', CASE WHEN pb.precio IS NOT NULL
                                   THEN '$' || miles(round(u.n * pb.precio)) END,
                 -- 054: si el stock con el que se decidió pedir era estimado,
                 -- la lista lo dice. Comprar de más por una cuenta inventada es
                 -- exactamente el error que A2 vino a evitar.
                 'stock_estimado', (r.origen_stock = 'estimado'),
                 'prioridad', r.prioridad)) AS x
        FROM recomendaciones r
        CROSS JOIN LATERAL (
            SELECT nullif(r.datos ->> 'unidades_pedir', '')::numeric AS n) u
        LEFT JOIN v_proveedor_mas_barato pb
               ON pb.negocio_id = r.negocio_id
              AND pb.producto_id = nullif(split_part(r.clave_objeto, ':', 2), '')::bigint
        WHERE r.negocio_id = p_negocio_id
          AND r.regla = 'agota'
          AND r.estado IN ('nueva','vigente')
          AND u.n IS NOT NULL AND u.n > 0
    ) s;

    RETURN jsonb_build_object(
      'items', v_items,
      'productos', jsonb_array_length(v_items),
      'total', round(v_total),
      'total_txt', '$' || miles(round(v_total)),
      -- Se declara, no se disimula: un total al que le faltan productos sin
      -- precio conocido no es el total de la compra.
      'sin_precio', v_sin,
      'generado_en', now());
END;
$function$
