CREATE OR REPLACE FUNCTION public.miles(p numeric)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT replace(to_char(round(coalesce(p, 0)), 'FM999,999,999,999'), ',', '.');
$function$
