CREATE OR REPLACE VIEW public.v_deriva_costo AS
 WITH compras AS (
         SELECT mov_visibles.negocio_id,
            mov_visibles.producto_id,
            mov_visibles.valor_unitario,
            mov_visibles.fecha,
            mov_visibles.id,
            first_value(mov_visibles.valor_unitario) OVER w AS costo_ini,
            last_value(mov_visibles.valor_unitario) OVER w AS costo_fin
           FROM mov_visibles
          WHERE mov_visibles.tipo = 'compra'::tipo_movimiento AND mov_visibles.producto_id IS NOT NULL AND mov_visibles.valor_unitario IS NOT NULL
          WINDOW w AS (PARTITION BY mov_visibles.negocio_id, mov_visibles.producto_id ORDER BY mov_visibles.fecha NULLS FIRST, mov_visibles.id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
        )
 SELECT DISTINCT negocio_id,
    producto_id,
    costo_ini,
    costo_fin,
    costo_fin - costo_ini AS deriva_abs,
    round((costo_fin - costo_ini) / NULLIF(costo_ini, 0::numeric) * 100::numeric, 2) AS deriva_pct
   FROM compras;
