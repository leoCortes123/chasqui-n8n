CREATE OR REPLACE FUNCTION public.teclado_consentimiento(p_contexto text DEFAULT ''::text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT jsonb_build_array(
      jsonb_build_array(jsonb_build_object(
        'texto', '✅ Acepto y continúo',
        'dato',  'acepto:' || CASE WHEN octet_length(coalesce(p_contexto,'')) <= 50
                                   THEN coalesce(p_contexto,'') ELSE '' END)),
      jsonb_build_array(jsonb_build_object(
        'texto', '🔐 Cómo trato tus datos', 'dato', '/privacidad')));
$function$
