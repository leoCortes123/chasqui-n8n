CREATE OR REPLACE FUNCTION public.portal_pedido()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RETURN pedido_sugerido(portal_negocio());
END;
$function$
