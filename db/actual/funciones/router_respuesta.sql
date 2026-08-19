CREATE OR REPLACE FUNCTION public.router_respuesta(p_chat bigint, p_plantilla text, p_vars jsonb DEFAULT '{}'::jsonb, p_teclado jsonb DEFAULT NULL::jsonb, p_acciones jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT jsonb_build_object(
      'chat_id', p_chat,
      'respuestas', CASE WHEN p_plantilla IS NULL THEN '[]'::jsonb
                    ELSE jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                           'plantilla', p_plantilla,
                           'vars', coalesce(p_vars, '{}'::jsonb),
                           'teclado', p_teclado))) END,
      'acciones', coalesce(p_acciones, '[]'::jsonb));
$function$
