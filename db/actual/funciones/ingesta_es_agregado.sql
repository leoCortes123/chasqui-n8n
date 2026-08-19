CREATE OR REPLACE FUNCTION public.ingesta_es_agregado(p_columnas jsonb)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT (p_columnas ? 'valor_total' OR p_columnas ? 'valor_unitario')
       AND NOT (p_columnas ? 'producto')
       AND NOT (p_columnas ? 'cantidad');
$function$
