CREATE OR REPLACE VIEW public.v_pareto_utilidad AS
 WITH util AS (
         SELECT m.negocio_id,
            m.producto_id,
            sum((m.valor_unitario - c.costo_actual) * m.cantidad) AS utilidad
           FROM mov_visibles m
             JOIN v_costo_actual_producto c ON c.negocio_id = m.negocio_id AND c.producto_id = m.producto_id
          WHERE m.tipo = 'venta'::tipo_movimiento AND m.producto_id IS NOT NULL
          GROUP BY m.negocio_id, m.producto_id
        ), ranked AS (
         SELECT util.negocio_id,
            util.producto_id,
            util.utilidad,
            sum(util.utilidad) OVER (PARTITION BY util.negocio_id) AS utilidad_total,
            sum(util.utilidad) OVER (PARTITION BY util.negocio_id ORDER BY util.utilidad DESC ROWS UNBOUNDED PRECEDING) AS utilidad_acum
           FROM util
        )
 SELECT negocio_id,
    producto_id,
    utilidad,
    round(utilidad / NULLIF(utilidad_total, 0::numeric) * 100::numeric, 2) AS pct_utilidad,
    round(utilidad_acum / NULLIF(utilidad_total, 0::numeric) * 100::numeric, 2) AS pct_acumulado
   FROM ranked
  ORDER BY negocio_id, utilidad DESC;
