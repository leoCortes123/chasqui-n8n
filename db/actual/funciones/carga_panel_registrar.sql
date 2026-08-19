CREATE OR REPLACE FUNCTION public.carga_panel_registrar(p_sesion_id bigint, p_mensaje_id bigint)
 RETURNS void
 LANGUAGE sql
AS $function$
    UPDATE sesiones SET panel_mensaje_id = p_mensaje_id WHERE id = p_sesion_id;
$function$
