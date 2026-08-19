CREATE OR REPLACE FUNCTION public.portal_conteo_guardar(p_producto_id bigint, p_unidades numeric, p_fecha date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_negocio bigint := portal_negocio();
    v_id      bigint;
BEGIN
    -- El producto tiene que ser de este negocio: el id llega del navegador.
    IF NOT EXISTS (SELECT 1 FROM productos
                   WHERE id = p_producto_id AND negocio_id = v_negocio) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'producto_ajeno');
    END IF;
    IF p_unidades IS NULL OR p_unidades < 0 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'unidades_invalidas');
    END IF;

    INSERT INTO conteos_inventario (negocio_id, producto_id, fecha, unidades, origen)
    VALUES (v_negocio, p_producto_id, coalesce(p_fecha, current_date), p_unidades, 'portal')
    ON CONFLICT (negocio_id, producto_id, fecha)
      DO UPDATE SET unidades = EXCLUDED.unidades, origen = 'portal'
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$
