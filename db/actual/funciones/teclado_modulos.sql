CREATE OR REPLACE FUNCTION public.teclado_modulos()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT coalesce(
             (SELECT jsonb_agg(jsonb_build_array(jsonb_build_object(
                       'texto', nombre, 'dato', 'mod:' || codigo)) ORDER BY orden)
                FROM modulos WHERE activo),
             '[]'::jsonb)
           || jsonb_build_array(jsonb_build_array(jsonb_build_object(
                'texto', '❓ Cómo funciona Chasqui', 'dato', '/comofunciona')));
$function$
