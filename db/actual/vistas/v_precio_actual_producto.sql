CREATE OR REPLACE VIEW public.v_precio_actual_producto AS
 SELECT DISTINCT ON (negocio_id, producto_id) negocio_id,
    producto_id,
    valor_unitario AS precio_actual,
    fecha AS fecha_precio
   FROM mov_visibles m
  WHERE tipo = 'venta'::tipo_movimiento AND producto_id IS NOT NULL AND valor_unitario IS NOT NULL
  ORDER BY negocio_id, producto_id, fecha DESC NULLS LAST, id DESC;
