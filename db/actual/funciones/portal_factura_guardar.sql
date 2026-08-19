CREATE OR REPLACE FUNCTION public.portal_factura_guardar(p_tercero text, p_total numeric, p_vencimiento date, p_numero text DEFAULT NULL::text, p_emision date DEFAULT NULL::date, p_nit text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_negocio bigint := portal_negocio();
    v_nombre  text   := nullif(btrim(coalesce(p_tercero, '')), '');
    v_terc    bigint;
    v_id      bigint;
BEGIN
    IF v_nombre IS NULL OR coalesce(p_total, 0) <= 0 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'faltan_datos');
    END IF;

    -- El tercero se reusa por nombre normalizado: sin esto, "Panadería El Sol"
    -- y "panaderia el sol" serían dos deudores distintos y la cartera de cada
    -- uno se vería la mitad de grande de lo que es.
    SELECT id INTO v_terc FROM terceros
    WHERE negocio_id = v_negocio AND norm_texto(nombre) = norm_texto(v_nombre)
    LIMIT 1;

    IF v_terc IS NULL THEN
        INSERT INTO terceros (negocio_id, nombre, nit)
        VALUES (v_negocio, v_nombre, nullif(btrim(coalesce(p_nit, '')), ''))
        RETURNING id INTO v_terc;
    END IF;

    INSERT INTO facturas (negocio_id, tercero_id, tipo, numero, emision,
                          vencimiento, total, saldo)
    VALUES (v_negocio, v_terc, 'venta', nullif(btrim(coalesce(p_numero,'')), ''),
            coalesce(p_emision, current_date), p_vencimiento,
            round(p_total), round(p_total))
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'factura_id', v_id,
                              'tercero_id', v_terc, 'tercero', v_nombre);
END;
$function$
