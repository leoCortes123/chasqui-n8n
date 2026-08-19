CREATE OR REPLACE FUNCTION public.portal_conteos(p_limite integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'id', c.id, 'producto', p.nombre_canonico, 'producto_id', p.id,
             'fecha', c.fecha, 'unidades', c.unidades, 'origen', c.origen)
             ORDER BY c.fecha DESC, c.id DESC), '[]'::jsonb)
    FROM (SELECT * FROM conteos_inventario
          WHERE negocio_id = portal_negocio()
          ORDER BY fecha DESC, id DESC
          LIMIT greatest(coalesce(p_limite, 50), 1)) c
    JOIN productos p ON p.id = c.producto_id;
$function$
