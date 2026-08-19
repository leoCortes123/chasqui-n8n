CREATE OR REPLACE FUNCTION public.portal_informes(p_limite integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    RETURN coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', e.id, 'servicio', s.nombre, 'servicio_codigo', e.servicio_codigo,
               'fecha', e.inicio, 'estado', e.estado,
               'resumen', left(regexp_replace(coalesce(e.texto, ''), '<[^>]+>', '', 'g'), 160))
             ORDER BY e.inicio DESC)
      FROM (SELECT * FROM ejecuciones
             WHERE negocio_id = v_negocio AND estado = 'completada'
             ORDER BY inicio DESC LIMIT greatest(coalesce(p_limite, 20), 1)) e
      LEFT JOIN servicios s ON s.codigo = e.servicio_codigo), '[]'::jsonb);
END;
$function$
