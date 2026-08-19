CREATE OR REPLACE FUNCTION public.esc_html(p_texto text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT replace(replace(replace(coalesce(p_texto, ''),
             '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
$function$
