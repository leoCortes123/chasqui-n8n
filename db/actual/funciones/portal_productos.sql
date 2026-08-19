CREATE OR REPLACE FUNCTION public.portal_productos()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'id', p.id, 'nombre', p.nombre_canonico, 'unidad', p.unidad,
             'stock', b.balance, 'origen_stock', b.origen_stock,
             'conteo_fecha', b.conteo_fecha)
             ORDER BY p.nombre_canonico), '[]'::jsonb)
    FROM productos p
    LEFT JOIN v_balance_unidades b
           ON b.negocio_id = p.negocio_id AND b.producto_id = p.id
    WHERE p.negocio_id = portal_negocio();
$function$
