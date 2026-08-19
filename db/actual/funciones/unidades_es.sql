CREATE OR REPLACE FUNCTION public.unidades_es(p_n numeric)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT CASE WHEN round(coalesce(p_n, 0)) = 1 THEN '1 unidad'
                ELSE round(coalesce(p_n, 0))::int::text || ' unidades' END;
$function$
