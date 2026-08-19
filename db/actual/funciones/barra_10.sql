CREATE OR REPLACE FUNCTION public.barra_10(p_valor numeric)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT repeat('█', greatest(0, least(10, round(coalesce(p_valor,0)/10)::int)))
        || repeat('░', 10 - greatest(0, least(10, round(coalesce(p_valor,0)/10)::int)));
$function$
