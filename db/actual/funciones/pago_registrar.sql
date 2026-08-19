CREATE OR REPLACE FUNCTION public.pago_registrar(p_factura_id bigint, p_valor numeric, p_fecha date DEFAULT NULL::date, p_medio text DEFAULT NULL::text, p_origen text DEFAULT 'portal'::text, p_usuario_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE v_saldo numeric;
BEGIN
    IF coalesce(p_valor, 0) <= 0 THEN
        RAISE EXCEPTION 'el pago debe ser mayor que cero' USING ERRCODE = '22023';
    END IF;

    SELECT saldo INTO v_saldo FROM facturas WHERE id = p_factura_id FOR UPDATE;
    IF v_saldo IS NULL THEN
        RAISE EXCEPTION 'no existe esa factura' USING ERRCODE = '42501';
    END IF;
    IF p_valor > v_saldo THEN
        RAISE EXCEPTION 'el pago (%) supera el saldo (%)', p_valor, v_saldo
              USING ERRCODE = '22023';
    END IF;

    INSERT INTO pagos (factura_id, fecha, valor, medio, origen, usuario_id)
    VALUES (p_factura_id, coalesce(p_fecha, current_date), p_valor,
            p_medio, p_origen, p_usuario_id);

    UPDATE facturas SET saldo = saldo - p_valor WHERE id = p_factura_id
    RETURNING saldo INTO v_saldo;

    RETURN jsonb_build_object('ok', true, 'saldo', v_saldo);
END;
$function$
