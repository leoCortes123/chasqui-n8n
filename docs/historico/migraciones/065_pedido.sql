-- 065_pedido.sql — las recomendaciones de "se agota" se convierten en una lista
-- de compra.
--
-- La regla R4 ya calcula, producto por producto, cuántas unidades pedir: lo que
-- se vende mientras el proveedor entrega, más el colchón. Pero lo entrega
-- disperso —un renglón por producto, dentro de un informe— y quien va a comprar
-- necesita **una lista**, con el total, para saber si le alcanza la plata.
--
-- Es el paso de "acá tenés seis avisos" a "esto es lo que hay que comprar esta
-- semana y cuesta $X". No se envía a ningún lado: no hay canal saliente a
-- terceros y no lo va a haber en esta fase. Es una lista para mirar, y a lo
-- sumo para leerle al proveedor por teléfono.
--
-- DE DÓNDE SALE CADA COLUMNA
--
--   producto     de la recomendación abierta (B2)
--   unidades     de `recomendaciones.datos ->> 'unidades_pedir'` (D1). No se
--                recalcula: es exactamente el número que se le mostró al dueño.
--   proveedor    el más barato al que YA le compró ese producto. No se inventa
--                un proveedor ni se sugiere uno que nunca usó.
--   costo        unidades × ese precio. Estimado, y dicho como estimado.
--
-- POR QUÉ NO SE RECALCULAN LAS UNIDADES
--
-- Sería fácil llamar de nuevo a la regla. Sería peor: el dueño vio "pedí 7" en
-- el informe del martes, y si el jueves la lista dice 9 porque entró una venta,
-- deja de confiar en las dos cifras. La lista muestra lo que se recomendó, y si
-- el número cambió es porque hay una recomendación nueva.

-- =============================================================================
-- 1. El proveedor más barato conocido
-- =============================================================================
-- "Conocido" es la palabra importante: sale de las compras del propio negocio,
-- no de una lista de precios de mercado que Chasqui no tiene. Si nunca le
-- compró ese producto a nadie, no hay proveedor y se dice.
CREATE OR REPLACE VIEW v_proveedor_mas_barato AS
SELECT DISTINCT ON (negocio_id, producto_id)
       negocio_id, producto_id, proveedor,
       round(precio_prom) AS precio,
       compras, ultima_compra
FROM (
    SELECT m.negocio_id, m.producto_id,
           nullif(btrim(coalesce(m.raw ->> 'proveedor', '')), '') AS proveedor,
           sum(m.valor_total) / nullif(sum(m.cantidad), 0) AS precio_prom,
           count(*)      AS compras,
           max(m.fecha)  AS ultima_compra
    FROM mov_visibles m
    WHERE m.tipo = 'compra' AND m.producto_id IS NOT NULL
      AND m.cantidad > 0 AND m.valor_total > 0
      AND nullif(btrim(coalesce(m.raw ->> 'proveedor', '')), '') IS NOT NULL
    GROUP BY 1, 2, 3
) s
ORDER BY negocio_id, producto_id, precio_prom, ultima_compra DESC;

COMMENT ON VIEW v_proveedor_mas_barato IS
  'El proveedor más barato al que el negocio YA le compró cada producto. Sale '
  'de sus propias compras: Chasqui no tiene precios de mercado y no los inventa.';

-- =============================================================================
-- 2. La lista
-- =============================================================================
CREATE OR REPLACE FUNCTION pedido_sugerido(p_negocio_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
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
$$;

COMMENT ON FUNCTION pedido_sugerido(bigint) IS
  'Las recomendaciones abiertas de "se agota", consolidadas en una lista de '
  'compra. Las unidades NO se recalculan: son las que se le mostraron al dueño.';

-- =============================================================================
-- 3. El portal
-- =============================================================================
CREATE OR REPLACE FUNCTION portal_pedido()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
BEGIN
    RETURN pedido_sugerido(portal_negocio());
END;
$$;

GRANT EXECUTE ON FUNCTION portal_pedido() TO portal_usuario;

NOTIFY pgrst, 'reload schema';
