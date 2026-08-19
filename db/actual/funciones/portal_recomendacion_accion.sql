CREATE OR REPLACE FUNCTION public.portal_recomendacion_accion(p_id bigint, p_accion text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RETURN recomendacion_accion(p_id, portal_negocio(), p_accion, NULL);
END;
$function$
