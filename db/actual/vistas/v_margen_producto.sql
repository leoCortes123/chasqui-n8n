CREATE OR REPLACE VIEW public.v_margen_producto AS
 SELECT p.negocio_id,
    p.id AS producto_id,
    p.nombre_canonico,
    c.costo_actual,
    pr.precio_actual,
    pr.precio_actual - c.costo_actual AS margen_abs,
    round((pr.precio_actual - c.costo_actual) / NULLIF(pr.precio_actual, 0::numeric) * 100::numeric, 2) AS margen_pct
   FROM productos p
     LEFT JOIN v_costo_actual_producto c ON c.negocio_id = p.negocio_id AND c.producto_id = p.id
     LEFT JOIN v_precio_actual_producto pr ON pr.negocio_id = p.negocio_id AND pr.producto_id = p.id;
