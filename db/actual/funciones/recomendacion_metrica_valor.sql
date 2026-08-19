CREATE OR REPLACE FUNCTION public.recomendacion_metrica_valor(p_negocio_id bigint, p_clave text, p_metrica text, p_desde date DEFAULT NULL::date)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_prod bigint := CASE WHEN p_clave LIKE 'producto:%'
                          THEN nullif(split_part(p_clave, ':', 2), '')::bigint END;
    v_terc bigint := CASE WHEN p_clave LIKE 'tercero:%'
                          THEN nullif(split_part(p_clave, ':', 2), '')::bigint END;
    v_val  numeric;
BEGIN
    IF p_metrica = 'costo' THEN
        SELECT costo_actual INTO v_val FROM v_margen_producto
        WHERE negocio_id = p_negocio_id AND producto_id = v_prod;

    ELSIF p_metrica = 'margen_pct' THEN
        SELECT margen_pct INTO v_val FROM v_margen_producto
        WHERE negocio_id = p_negocio_id AND producto_id = v_prod;

    ELSIF p_metrica = 'dias_cobertura' THEN
        SELECT dias_cobertura INTO v_val FROM v_rotacion_producto
        WHERE negocio_id = p_negocio_id AND producto_id = v_prod;

    ELSIF p_metrica = 'balance' THEN
        SELECT balance INTO v_val FROM v_balance_unidades
        WHERE negocio_id = p_negocio_id AND producto_id = v_prod;

    ELSIF p_metrica = 'unidades_vendidas' THEN
        SELECT coalesce(sum(cantidad), 0) INTO v_val FROM mov_visibles
        WHERE negocio_id = p_negocio_id AND tipo = 'venta'
          AND producto_id = v_prod
          AND (p_desde IS NULL OR fecha >= p_desde);

    ELSIF p_metrica = 'ventas' THEN
        SELECT coalesce(sum(valor_total), 0) INTO v_val FROM mov_visibles
        WHERE negocio_id = p_negocio_id AND tipo = 'venta'
          AND (p_desde IS NULL OR fecha >= p_desde);

    ELSIF p_metrica = 'concentracion_pct' THEN
        SELECT max(gasto) * 100.0 / nullif(sum(gasto), 0) INTO v_val
        FROM (SELECT nullif(btrim(coalesce(raw ->> 'proveedor','')),'') AS prov,
                     sum(valor_total) AS gasto
              FROM mov_visibles
              WHERE negocio_id = p_negocio_id AND tipo = 'compra'
                AND nullif(btrim(coalesce(raw ->> 'proveedor','')),'') IS NOT NULL
              GROUP BY 1) g;

    -- >>> 069: lo que ese cliente todavía debe y ya venció.
    ELSIF p_metrica = 'saldo_vencido' THEN
        SELECT coalesce(sum(saldo), 0) INTO v_val FROM facturas
        WHERE negocio_id = p_negocio_id AND tercero_id = v_terc
          AND tipo = 'venta' AND saldo > 0
          AND vencimiento IS NOT NULL AND vencimiento < current_date;
    END IF;

    RETURN v_val;
END;
$function$
