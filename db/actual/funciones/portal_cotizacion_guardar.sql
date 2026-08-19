CREATE OR REPLACE FUNCTION public.portal_cotizacion_guardar(p_items jsonb, p_cliente text DEFAULT NULL::text, p_notas text DEFAULT NULL::text, p_vigente_hasta date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_negocio bigint := portal_negocio();
    v_usuario bigint := portal_claim('usuario_id');
    v_items   jsonb;
    v_total   numeric;
    v_id      bigint;
    v_token   text := encode(gen_random_bytes(12), 'hex');
BEGIN
    -- Normalizar y validar en un solo paso: título obligatorio, cantidad > 0,
    -- valor >= 0. El total de cada línea y el general se calculan acá; lo que
    -- mande el navegador en esos campos se ignora.
    SELECT jsonb_agg(jsonb_build_object(
             'titulo', i.titulo, 'unidad', i.unidad,
             'cantidad', i.cantidad, 'valor_unitario', i.valor,
             'total', round(i.cantidad * i.valor))),
           coalesce(sum(round(i.cantidad * i.valor)), 0)
      INTO v_items, v_total
    FROM (SELECT btrim(coalesce(e ->> 'titulo', ''))            AS titulo,
                 nullif(btrim(coalesce(e ->> 'unidad', '')), '') AS unidad,
                 (e ->> 'cantidad')::numeric                     AS cantidad,
                 (e ->> 'valor_unitario')::numeric               AS valor
          FROM jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) e) i
    WHERE i.titulo <> '' AND i.cantidad > 0 AND i.valor >= 0;

    IF v_items IS NULL OR jsonb_array_length(v_items) = 0 THEN
        RAISE EXCEPTION 'la cotización necesita al menos un producto con cantidad'
              USING ERRCODE = '22023';
    END IF;

    INSERT INTO cotizaciones (negocio_id, creado_por, cliente, notas, items,
                              total, token, vigente_hasta)
    VALUES (v_negocio, v_usuario, nullif(btrim(coalesce(p_cliente, '')), ''),
            nullif(btrim(coalesce(p_notas, '')), ''), v_items, v_total,
            v_token, p_vigente_hasta)
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'id', v_id, 'token', v_token,
                              'total', v_total);
END;
$function$
