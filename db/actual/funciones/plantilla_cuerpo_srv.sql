CREATE OR REPLACE FUNCTION public.plantilla_cuerpo_srv(p_clave text, p_servicio text, p_defecto text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
    SELECT coalesce(
      (SELECT cuerpo FROM plantillas
        WHERE clave = p_clave || '.' || coalesce(p_servicio, '—') AND activo LIMIT 1),
      (SELECT cuerpo FROM plantillas WHERE clave = p_clave AND activo LIMIT 1),
      p_defecto);
$function$
