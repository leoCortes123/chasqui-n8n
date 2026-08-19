CREATE OR REPLACE FUNCTION public.cifra_norm(p_num text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT CASE WHEN strpos(coalesce(p_num, ''), '.') = 0 THEN coalesce(p_num, '')
                ELSE regexp_replace(regexp_replace(p_num, '0+$', ''), '\.$', '') END;
$function$
