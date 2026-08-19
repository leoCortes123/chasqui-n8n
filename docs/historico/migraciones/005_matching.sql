-- 005_matching.sql — resolver el texto libre de una línea a un producto canónico.
-- El nombre en una factura ("ARROZ DIANA 500G") y en el POS ("Arroz Diana x500")
-- son el mismo producto. Sin esto, márgenes y rotación se calculan sobre basura.
--
-- Estrategia: las compras DIAN traen código de barras (identificación fiable) y
-- SIEMBRAN el catálogo. Las ventas POS, sin código, hacen match por trigram
-- contra ese catálogo ya sembrado. Es el orden real del negocio.

-- Código de barras en productos (para siembra desde DIAN).
ALTER TABLE productos ADD COLUMN codigo_barras text;
CREATE UNIQUE INDEX uq_producto_barras ON productos(negocio_id, codigo_barras)
    WHERE codigo_barras IS NOT NULL;

-- Umbral de auto-confirmación por trigram. Sobre esto se asigna solo; debajo,
-- queda pendiente de que el usuario confirme.
-- (parametrizable por negocio vía parametros: clave 'match_umbral_trgm')

CREATE FUNCTION match_resolver_producto(p_negocio_id bigint, p_texto text)
RETURNS jsonb LANGUAGE plpgsql AS $$
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
$$;

-- Confirmación manual de un alias pendiente (desde wf_admin o el flujo de
-- intake). Reaplica el alias a los movimientos que quedaron sin producto.
CREATE FUNCTION match_confirmar_alias(p_alias_id bigint, p_producto_id bigint)
RETURNS void LANGUAGE plpgsql AS $$
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
$$;

-- Resuelve todos los movimientos de un documento recién parseado.
-- wf_ingesta la llama después de ingesta_procesar_documento.
CREATE FUNCTION match_resolver_documento(p_documento_id bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
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
$$;
