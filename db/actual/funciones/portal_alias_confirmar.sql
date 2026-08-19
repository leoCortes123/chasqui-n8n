CREATE OR REPLACE FUNCTION public.portal_alias_confirmar(p_alias_id bigint, p_producto_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    -- Las dos puntas tienen que ser del negocio de la sesión. Sin esto, la RPC
    -- sería una forma de mover productos entre negocios.
    IF NOT EXISTS (SELECT 1 FROM alias
                    WHERE id = p_alias_id AND negocio_id = v_negocio
                      AND producto_id IS NULL)
       OR NOT EXISTS (SELECT 1 FROM productos
                       WHERE id = p_producto_id AND negocio_id = v_negocio) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_encontrado');
    END IF;

    PERFORM match_confirmar_alias(p_alias_id, p_producto_id);

    RETURN jsonb_build_object('ok', true,
      'movimientos', (SELECT count(*) FROM movimientos
                       WHERE negocio_id = v_negocio AND alias_id = p_alias_id));
END;
$function$
