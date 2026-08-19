CREATE OR REPLACE FUNCTION public.teclado_modulo(p_codigo text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT coalesce(
             (SELECT jsonb_agg(jsonb_build_array(jsonb_build_object(
                       'texto', nombre, 'dato', 'svc:' || codigo)) ORDER BY orden)
                FROM servicios
               WHERE activo AND entrada = 'archivos' AND modulo_codigo = p_codigo),
             '[]'::jsonb)
           || jsonb_build_array(
                jsonb_build_array(jsonb_build_object(
                  'texto', '❓ Cómo funciona', 'dato', 'modayuda:' || p_codigo)),
                jsonb_build_array(jsonb_build_object(
                  'texto', '⬅️ Volver', 'dato', '/ayuda')));
$function$
