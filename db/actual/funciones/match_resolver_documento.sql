CREATE OR REPLACE FUNCTION public.match_resolver_documento(p_documento_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_negocio_id bigint;
    m            record;
    v_texto      text;
    v_codigo     text;
    v_prod_id    bigint;
    v_res        jsonb;
    v_total      int := 0;
    v_resueltos  int := 0;
    v_pendientes int := 0;
    v_nuevos     int := 0;
BEGIN
    SELECT negocio_id INTO v_negocio_id FROM documentos WHERE id = p_documento_id;

    FOR m IN
        SELECT id, tipo, raw FROM movimientos
        WHERE documento_id = p_documento_id AND producto_id IS NULL
    LOOP
        v_total := v_total + 1;
        v_texto  := coalesce(m.raw ->> 'descripcion', m.raw ->> 'producto');
        v_codigo := nullif(m.raw ->> 'codigo', '');
        v_prod_id := NULL;

        -- (a) Compra con código de barras: siembra/reusa producto por código.
        IF v_codigo IS NOT NULL THEN
            SELECT id INTO v_prod_id FROM productos
            WHERE negocio_id = v_negocio_id AND codigo_barras = v_codigo;

            IF v_prod_id IS NULL THEN
                INSERT INTO productos (negocio_id, nombre_canonico, codigo_barras,
                                       unidad, categoria)
                VALUES (v_negocio_id, coalesce(v_texto, v_codigo), v_codigo,
                        m.raw ->> 'unidad', NULL)
                RETURNING id INTO v_prod_id;
                v_nuevos := v_nuevos + 1;
            END IF;

            -- memoriza el texto como alias exacto para el POS futuro
            IF v_texto IS NOT NULL THEN
                INSERT INTO alias (negocio_id, texto_norm, producto_id, confianza, origen)
                VALUES (v_negocio_id, norm_texto(v_texto), v_prod_id, 1.0, 'exacto')
                ON CONFLICT (negocio_id, texto_norm)
                  DO UPDATE SET producto_id = EXCLUDED.producto_id, origen = 'exacto';
            END IF;

            UPDATE movimientos SET producto_id = v_prod_id WHERE id = m.id;
            v_resueltos := v_resueltos + 1;
            CONTINUE;
        END IF;

        -- (b) Sin código: resolver por texto (alias exacto / trigram / pendiente).
        v_res := match_resolver_producto(v_negocio_id, v_texto);
        IF (v_res ->> 'resuelto')::boolean THEN
            UPDATE movimientos
            SET producto_id = (v_res ->> 'producto_id')::bigint,
                alias_id    = (v_res ->> 'alias_id')::bigint
            WHERE id = m.id;
            v_resueltos := v_resueltos + 1;
        ELSE
            UPDATE movimientos SET alias_id = (v_res ->> 'alias_id')::bigint
            WHERE id = m.id;
            v_pendientes := v_pendientes + 1;
        END IF;
    END LOOP;

    RETURN jsonb_build_object('documento_id', p_documento_id, 'total', v_total,
                              'resueltos', v_resueltos, 'pendientes', v_pendientes,
                              'productos_nuevos', v_nuevos);
END;
$function$
