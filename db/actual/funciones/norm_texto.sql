CREATE OR REPLACE FUNCTION public.norm_texto(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT btrim(regexp_replace(lower(unaccent(coalesce(p, ''))), '\s+', ' ', 'g'));
$function$
