CREATE OR REPLACE FUNCTION public.portal_claim(p_clave text)
 RETURNS bigint
 LANGUAGE sql
 STABLE
AS $function$
    SELECT nullif(current_setting('request.jwt.claims', true)::jsonb ->> p_clave, '')::bigint;
$function$
