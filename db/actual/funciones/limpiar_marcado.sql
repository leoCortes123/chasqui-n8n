CREATE OR REPLACE FUNCTION public.limpiar_marcado(p_texto text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT btrim(regexp_replace(
             regexp_replace(coalesce(p_texto, ''), '\*\*|__', '', 'g'),
             '^\s*#{1,6}\s*', '', 'g'));
$function$
