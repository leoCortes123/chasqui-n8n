CREATE OR REPLACE FUNCTION public.portal_informe(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_negocio bigint := portal_negocio();
    v_out     jsonb;
BEGIN
    SELECT jsonb_build_object('id', e.id, 'servicio', s.nombre,
             'fecha', e.inicio, 'texto', e.texto)
      INTO v_out
    FROM ejecuciones e LEFT JOIN servicios s ON s.codigo = e.servicio_codigo
    WHERE e.id = p_id AND e.negocio_id = v_negocio AND e.estado = 'completada';

    RETURN coalesce(v_out, jsonb_build_object('error', 'no_existe'));
END;
$function$
