CREATE OR REPLACE FUNCTION public.plantilla_cuerpo(p_clave text, p_defecto text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
    SELECT coalesce((SELECT cuerpo FROM plantillas
                     WHERE clave = p_clave AND activo LIMIT 1), p_defecto);
$function$
