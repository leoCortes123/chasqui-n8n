CREATE OR REPLACE VIEW public.v_rotacion_producto AS
 WITH ventas AS (
         SELECT mov_visibles.negocio_id,
            mov_visibles.producto_id,
            sum(mov_visibles.cantidad) AS unidades,
            GREATEST(max(mov_visibles.fecha) - min(mov_visibles.fecha), 1) AS dias_ventana
           FROM mov_visibles
          WHERE mov_visibles.tipo = 'venta'::tipo_movimiento AND mov_visibles.producto_id IS NOT NULL
          GROUP BY mov_visibles.negocio_id, mov_visibles.producto_id
        )
 SELECT v.negocio_id,
    v.producto_id,
    v.unidades,
    v.dias_ventana,
    round(v.unidades / v.dias_ventana::numeric, 3) AS unidades_por_dia,
        CASE
            WHEN v.unidades > 0::numeric THEN round(b.balance / (v.unidades / v.dias_ventana::numeric), 1)
            ELSE NULL::numeric
        END AS dias_cobertura,
    b.origen_stock
   FROM ventas v
     LEFT JOIN v_balance_unidades b ON b.negocio_id = v.negocio_id AND b.producto_id = v.producto_id;
