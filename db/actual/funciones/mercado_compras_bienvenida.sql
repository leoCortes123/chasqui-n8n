CREATE OR REPLACE FUNCTION public.mercado_compras_bienvenida(p_negocio_id bigint, p_chat_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v record;
BEGIN
    SELECT count(DISTINCT m.documento_id)                              AS documentos,
           count(DISTINCT coalesce(p.nombre_canonico,
                 m.raw ->> 'descripcion', m.raw ->> 'producto'))       AS productos,
           round(coalesce(sum(m.valor_total), 0))                      AS gasto,
           min(m.fecha) AS desde, max(m.fecha) AS hasta
    INTO v
    FROM mov_visibles m
    LEFT JOIN productos p ON p.id = m.producto_id
    WHERE m.negocio_id = p_negocio_id AND m.tipo = 'compra';

    IF coalesce(v.documentos, 0) = 0 THEN
        RETURN router_respuesta(p_chat_id, 'mercado.pedir_facturas');
    END IF;

    RETURN router_respuesta(p_chat_id, 'mercado.datos_previos', jsonb_build_object(
        'documentos', v.documentos,
        'productos',  v.productos,
        'gasto',      '$' || miles(v.gasto),
        'rango',      coalesce(' ' || nullif(periodo_es(v.desde, v.hasta), ''), '')));
END;
$function$
