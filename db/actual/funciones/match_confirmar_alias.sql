CREATE OR REPLACE FUNCTION public.match_confirmar_alias(p_alias_id bigint, p_producto_id bigint)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_negocio_id bigint;
    v_norm       text;
BEGIN
    UPDATE alias SET producto_id = p_producto_id, origen = 'manual', confianza = 1.0
    WHERE id = p_alias_id
    RETURNING negocio_id, texto_norm INTO v_negocio_id, v_norm;

    -- Los movimientos ya cargados que apuntaban a este alias (o cuyo texto
    -- normalizado coincide) heredan el producto confirmado.
    UPDATE movimientos m
    SET producto_id = p_producto_id, alias_id = p_alias_id
    WHERE m.negocio_id = v_negocio_id
      AND m.producto_id IS NULL
      AND (m.alias_id = p_alias_id
           OR norm_texto(m.raw ->> 'descripcion') = v_norm
           OR norm_texto(m.raw ->> 'producto') = v_norm);
END;
$function$
