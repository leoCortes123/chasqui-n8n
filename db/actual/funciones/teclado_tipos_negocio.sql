CREATE OR REPLACE FUNCTION public.teclado_tipos_negocio()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT coalesce(jsonb_agg(jsonb_build_array(jsonb_build_object(
             'texto', nombre, 'dato', 'tipo:' || codigo)) ORDER BY orden), '[]'::jsonb)
    FROM tipos_negocio WHERE activo;
$function$
