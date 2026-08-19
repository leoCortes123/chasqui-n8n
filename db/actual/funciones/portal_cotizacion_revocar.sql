CREATE OR REPLACE FUNCTION public.portal_cotizacion_revocar(p_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_negocio bigint := portal_negocio();
    v_n       int;
BEGIN
    UPDATE cotizaciones SET estado = 'revocada'
    WHERE id = p_id AND negocio_id = v_negocio;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN jsonb_build_object('ok', v_n > 0);
END;
$function$
