CREATE OR REPLACE FUNCTION public.match_resolver_producto(p_negocio_id bigint, p_texto text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_norm     text := norm_texto(p_texto);
    v_umbral   real := coalesce((parametro(p_negocio_id, 'match_umbral_trgm'))::text::real, 0.45);
    v_alias_id bigint;
    v_prod_id  bigint;
    v_sim      real;
    v_nombre   text;
BEGIN
    IF v_norm = '' THEN
        RETURN jsonb_build_object('resuelto', false, 'motivo', 'texto vacío');
    END IF;

    -- 1. Alias exacto ya conocido y ya resuelto.
    SELECT a.id, a.producto_id INTO v_alias_id, v_prod_id
    FROM alias a
    WHERE a.negocio_id = p_negocio_id AND a.texto_norm = v_norm
    LIMIT 1;

    IF FOUND AND v_prod_id IS NOT NULL THEN
        SELECT nombre_canonico INTO v_nombre FROM productos WHERE id = v_prod_id;
        RETURN jsonb_build_object('resuelto', true, 'producto_id', v_prod_id,
                                  'producto', v_nombre, 'alias_id', v_alias_id,
                                  'origen', 'exacto');
    END IF;

    -- 2. Trigram contra productos existentes del negocio.
    SELECT p.id, p.nombre_canonico, similarity(norm_texto(p.nombre_canonico), v_norm)
      INTO v_prod_id, v_nombre, v_sim
    FROM productos p
    WHERE p.negocio_id = p_negocio_id
    ORDER BY similarity(norm_texto(p.nombre_canonico), v_norm) DESC
    LIMIT 1;

    IF v_prod_id IS NOT NULL AND v_sim >= v_umbral THEN
        -- Auto-confirma y memoriza el alias para la próxima.
        IF v_alias_id IS NULL THEN
            INSERT INTO alias (negocio_id, texto_norm, producto_id, confianza, origen)
            VALUES (p_negocio_id, v_norm, v_prod_id, v_sim, 'trigram')
            ON CONFLICT (negocio_id, texto_norm)
              DO UPDATE SET producto_id = EXCLUDED.producto_id,
                            confianza = EXCLUDED.confianza, origen = 'trigram'
            RETURNING id INTO v_alias_id;
        ELSE
            UPDATE alias SET producto_id = v_prod_id, confianza = v_sim, origen = 'trigram'
            WHERE id = v_alias_id;
        END IF;

        RETURN jsonb_build_object('resuelto', true, 'producto_id', v_prod_id,
                                  'producto', v_nombre, 'alias_id', v_alias_id,
                                  'origen', 'trigram', 'similitud', round(v_sim::numeric, 3));
    END IF;

    -- 3. Nada bueno: deja el texto como alias pendiente. No inventa producto.
    IF v_alias_id IS NULL THEN
        INSERT INTO alias (negocio_id, texto_norm, origen)
        VALUES (p_negocio_id, v_norm, 'pendiente')
        ON CONFLICT (negocio_id, texto_norm) DO NOTHING
        RETURNING id INTO v_alias_id;
        IF v_alias_id IS NULL THEN
            SELECT id INTO v_alias_id FROM alias
            WHERE negocio_id = p_negocio_id AND texto_norm = v_norm;
        END IF;
    END IF;

    RETURN jsonb_build_object('resuelto', false, 'alias_id', v_alias_id,
                              'texto', v_norm, 'origen', 'pendiente',
                              'mejor_candidato', v_nombre,
                              'similitud', round(coalesce(v_sim,0)::numeric, 3));
END;
$function$
