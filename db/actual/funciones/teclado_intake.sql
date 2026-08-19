CREATE OR REPLACE FUNCTION public.teclado_intake()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT CASE WHEN (SELECT count(*) FROM modulos WHERE activo) = 1
                THEN teclado_modulo((SELECT codigo FROM modulos WHERE activo))
                ELSE teclado_modulos()
           END;
$function$
