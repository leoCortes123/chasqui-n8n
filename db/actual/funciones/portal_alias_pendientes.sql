CREATE OR REPLACE FUNCTION public.portal_alias_pendientes(p_limite integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    RETURN jsonb_build_object(
      'pendientes', alias_pendientes(v_negocio, p_limite),
      'resumen', (SELECT jsonb_build_object(
                    'movs_sin_producto',   movs_sin_producto,
                    'dinero_sin_producto', dinero_sin_producto,
                    'pct_dinero_fuera',    coalesce(pct_dinero_fuera, 0))
                  FROM v_calidad_matching WHERE negocio_id = v_negocio));
END;
$function$
