CREATE OR REPLACE FUNCTION public.portal_cotizaciones(p_limite integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    RETURN coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', c.id, 'cliente', c.cliente, 'total', c.total,
               'estado', c.estado, 'token', c.token,
               'items', jsonb_array_length(c.items),
               'vigente_hasta', c.vigente_hasta, 'creado_en', c.creado_en)
             ORDER BY c.creado_en DESC, c.id DESC)
      FROM (SELECT * FROM cotizaciones WHERE negocio_id = v_negocio
            ORDER BY creado_en DESC, id DESC
            LIMIT greatest(coalesce(p_limite, 30), 1)) c), '[]'::jsonb);
END;
$function$
