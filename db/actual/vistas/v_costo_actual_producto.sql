CREATE OR REPLACE VIEW public.v_costo_actual_producto AS
 SELECT DISTINCT ON (negocio_id, producto_id) negocio_id,
    producto_id,
    valor_unitario AS costo_actual,
    fecha AS fecha_costo
   FROM mov_visibles m
  WHERE tipo = 'compra'::tipo_movimiento AND producto_id IS NOT NULL AND valor_unitario IS NOT NULL
  ORDER BY negocio_id, producto_id, fecha DESC NULLS LAST, id DESC;
