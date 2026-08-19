CREATE OR REPLACE FUNCTION public.norm_pregunta(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT btrim(regexp_replace(
             regexp_replace(norm_texto(p), '[^a-z0-9ñ ]', '', 'g'), '\s+', ' ', 'g'));
$function$
