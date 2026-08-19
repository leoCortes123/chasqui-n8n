CREATE OR REPLACE FUNCTION public.portal_perfil()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RETURN perfil_negocio(portal_negocio());
END;
$function$
