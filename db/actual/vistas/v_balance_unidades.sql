CREATE OR REPLACE VIEW public.v_balance_unidades AS
 WITH ultimo_conteo AS (
         SELECT DISTINCT ON (conteos_inventario.negocio_id, conteos_inventario.producto_id) conteos_inventario.negocio_id,
            conteos_inventario.producto_id,
            conteos_inventario.fecha AS conteo_fecha,
            conteos_inventario.unidades AS conteo_unidades
           FROM conteos_inventario
          ORDER BY conteos_inventario.negocio_id, conteos_inventario.producto_id, conteos_inventario.fecha DESC, conteos_inventario.id DESC
        )
 SELECT p.negocio_id,
    p.id AS producto_id,
    COALESCE(sum(m.cantidad) FILTER (WHERE m.tipo = 'compra'::tipo_movimiento), 0::numeric) AS compradas,
    COALESCE(sum(m.cantidad) FILTER (WHERE m.tipo = 'venta'::tipo_movimiento), 0::numeric) AS vendidas,
        CASE
            WHEN c.conteo_fecha IS NULL THEN COALESCE(sum(m.cantidad) FILTER (WHERE m.tipo = 'compra'::tipo_movimiento), 0::numeric) - COALESCE(sum(m.cantidad) FILTER (WHERE m.tipo = 'venta'::tipo_movimiento), 0::numeric)
            ELSE c.conteo_unidades + COALESCE(sum(m.cantidad) FILTER (WHERE m.tipo = 'compra'::tipo_movimiento AND m.fecha > c.conteo_fecha), 0::numeric) - COALESCE(sum(m.cantidad) FILTER (WHERE m.tipo = 'venta'::tipo_movimiento AND m.fecha > c.conteo_fecha), 0::numeric)
        END AS balance,
        CASE
            WHEN c.conteo_fecha IS NULL THEN 'estimado'::text
            WHEN count(*) FILTER (WHERE m.fecha > c.conteo_fecha) = 0 THEN 'conteo'::text
            ELSE 'calculado'::text
        END AS origen_stock,
    c.conteo_fecha,
    c.conteo_unidades
   FROM productos p
     LEFT JOIN ultimo_conteo c ON c.negocio_id = p.negocio_id AND c.producto_id = p.id
     LEFT JOIN mov_visibles m ON m.producto_id = p.id AND m.negocio_id = p.negocio_id
  GROUP BY p.negocio_id, p.id, c.conteo_fecha, c.conteo_unidades;
