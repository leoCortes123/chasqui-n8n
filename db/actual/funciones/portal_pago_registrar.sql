CREATE OR REPLACE FUNCTION public.portal_pago_registrar(p_factura_id bigint, p_valor numeric, p_fecha date DEFAULT NULL::date, p_medio text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_negocio bigint := portal_negocio();
    v_usuario bigint := portal_claim('usuario_id');
BEGIN
    IF NOT EXISTS (SELECT 1 FROM facturas
                   WHERE id = p_factura_id AND negocio_id = v_negocio) THEN
        RAISE EXCEPTION 'no existe esa factura' USING ERRCODE = '42501';
    END IF;

    RETURN pago_registrar(p_factura_id, p_valor, p_fecha, p_medio,
                          'portal', v_usuario);
END;
$function$
