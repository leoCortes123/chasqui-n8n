CREATE OR REPLACE FUNCTION public.portal_conocimiento_borrar(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_negocio bigint := portal_negocio();
    v_n       int;
BEGIN
    -- Las pendientes que este hecho resolvía vuelven a la lista: si se borra la
    -- respuesta, la pregunta sigue sin contestar.
    UPDATE conocimiento_pendiente SET resuelto_por = NULL
    WHERE resuelto_por = p_id AND negocio_id = v_negocio;

    DELETE FROM conocimiento WHERE id = p_id AND negocio_id = v_negocio;
    GET DIAGNOSTICS v_n = ROW_COUNT;

    RETURN jsonb_build_object('ok', v_n > 0);
END;
$function$
