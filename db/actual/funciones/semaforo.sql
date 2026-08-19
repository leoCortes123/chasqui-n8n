CREATE OR REPLACE FUNCTION public.semaforo(p_valor numeric)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT CASE WHEN p_valor IS NULL THEN '⚪'
                WHEN p_valor >= 80 THEN '🟢'
                WHEN p_valor >= 65 THEN '🟡'
                WHEN p_valor >= 50 THEN '🟠'
                ELSE '🔴' END;
$function$
