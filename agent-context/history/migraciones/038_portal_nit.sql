-- 038_portal_nit.sql — el NIT del negocio se captura en el portal.
--
-- Es la pieza que activa el lado "te deben" de la cartera: sin NIT,
-- cartera_facturar_dian no puede saber si el negocio es el emisor y todo entra
-- como compra. Se pide en el portal y no por chat porque es un dato que
-- conviene validar (dígito de verificación DIAN) y corregir en un formulario,
-- no en un diálogo.

-- =============================================================================
-- 1. Dígito de verificación DIAN
-- =============================================================================
-- El algoritmo oficial: pesos primos sobre los dígitos de derecha a izquierda,
-- módulo 11; si el residuo es 0 o 1 el DV es el residuo, si no 11 - residuo.

CREATE OR REPLACE FUNCTION nit_dv(p_nit text)
RETURNS int LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_pesos int[] := ARRAY[3,7,13,17,19,23,29,37,41,43,47,53,59,67,71];
    v_suma  int := 0;
    v_res   int;
    i       int;
BEGIN
    IF p_nit !~ '^\d{1,15}$' THEN
        RETURN NULL;
    END IF;
    FOR i IN 1..length(p_nit) LOOP
        -- dígito i-ésimo desde la derecha por el peso i-ésimo
        v_suma := v_suma + substr(p_nit, length(p_nit) - i + 1, 1)::int * v_pesos[i];
    END LOOP;
    v_res := v_suma % 11;
    RETURN CASE WHEN v_res IN (0, 1) THEN v_res ELSE 11 - v_res END;
END;
$$;

-- =============================================================================
-- 2. Guardar el NIT desde el portal
-- =============================================================================
-- Acepta "900.123.456-7", "900123456-7" o "900123456". Se guarda SIN dígito de
-- verificación, porque así viene el CompanyID en el XML de la DIAN y así lo
-- compara cartera_facturar_dian. Si el usuario escribió el DV (con guion), se
-- verifica; si no lo escribió, no se puede exigir: la cédula de una persona
-- natural también es un NIT válido y no lleva DV a la vista.

CREATE OR REPLACE FUNCTION portal_negocio_guardar(p_nit text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE
    v_negocio bigint := portal_negocio();
    v_crudo   text := regexp_replace(coalesce(p_nit, ''), '[.\s]', '', 'g');
    v_base    text;
    v_dv      text;
BEGIN
    -- Borrar el NIT es legítimo (se escribió mal, el negocio cambió de figura).
    IF v_crudo = '' THEN
        UPDATE negocios SET nit = NULL WHERE id = v_negocio;
        RETURN jsonb_build_object('ok', true, 'nit', NULL);
    END IF;

    v_base := split_part(v_crudo, '-', 1);
    v_dv   := nullif(split_part(v_crudo, '-', 2), '');

    IF v_base !~ '^\d{5,15}$' THEN
        RETURN jsonb_build_object('ok', false, 'error',
                 'El NIT debe tener solo números (entre 5 y 15 dígitos), con o sin -DV.');
    END IF;

    IF v_dv IS NOT NULL AND v_dv <> nit_dv(v_base)::text THEN
        RETURN jsonb_build_object('ok', false, 'error',
                 format('El dígito de verificación no cuadra: para %s sería %s.',
                        v_base, nit_dv(v_base)));
    END IF;

    UPDATE negocios SET nit = v_base WHERE id = v_negocio;

    -- Con el NIT nuevo, las facturas DIAN ya ingeridas pueden cambiar de lado
    -- (compra -> venta). Se re-facturan acá mismo: es la misma función del
    -- backfill de la 036, actualiza en vez de duplicar y conserva los pagos.
    PERFORM cartera_refacturar(v_negocio);

    RETURN jsonb_build_object('ok', true, 'nit', v_base, 'dv', nit_dv(v_base));
END;
$$;

GRANT EXECUTE ON FUNCTION portal_negocio_guardar(text) TO portal_usuario;

CREATE OR REPLACE FUNCTION cartera_refacturar(p_negocio_id bigint)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
    FOR r IN SELECT id FROM documentos
             WHERE negocio_id = p_negocio_id
               AND formato_codigo = 'dian_xml' AND estado = 'parseado' LOOP
        BEGIN
            PERFORM cartera_facturar_dian(r.id);
        EXCEPTION WHEN OTHERS THEN
            -- un XML viejo ilegible no debe frenar el cambio de NIT
            NULL;
        END;
    END LOOP;
END;
$$;

-- =============================================================================
-- 3. El empujón desde el chat
-- =============================================================================
-- Cuando entra una factura DIAN y el negocio no tiene NIT, el resumen que el
-- bot manda avisa que quedó como compra y manda al portal. El aviso se arma
-- acá (igual que el resto del resumen: de la base, no del LLM) y viaja como
-- una variable más de la plantilla; el nodo Respuesta de wf_ingesta solo la
-- pasa.

CREATE OR REPLACE FUNCTION ingesta_resumen_documento(p_documento_id bigint)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'nombre_archivo', d.nombre_archivo,
        'formato',        d.formato_codigo,
        'estado',         d.estado,
        'error',          d.error,
        'filas',          (SELECT count(*) FROM movimientos m WHERE m.documento_id = d.id),
        'desde',          (SELECT min(fecha) FROM movimientos m WHERE m.documento_id = d.id),
        'hasta',          (SELECT max(fecha) FROM movimientos m WHERE m.documento_id = d.id),
        'total',          (SELECT round(coalesce(sum(valor_total),0)) FROM movimientos m WHERE m.documento_id = d.id),
        'productos',      (SELECT count(DISTINCT coalesce(m.raw ->> 'producto', m.raw ->> 'descripcion'))
                             FROM movimientos m WHERE m.documento_id = d.id),
        'sin_resolver',   (SELECT count(*) FROM movimientos m
                            WHERE m.documento_id = d.id AND m.producto_id IS NULL),
        -- >>> nuevo respecto a la 017: si este documento generó factura y el
        -- negocio no tiene NIT, no se pudo saber de qué lado del mostrador está.
        'aviso_nit',      CASE WHEN EXISTS (SELECT 1 FROM facturas f WHERE f.documento_id = d.id)
                                AND (SELECT nullif(btrim(coalesce(n.nit, '')), '')
                                       FROM negocios n WHERE n.id = d.negocio_id) IS NULL
                          THEN ' 💡 La tomé como compra porque no tengo el NIT de tu negocio. Cargalo en tu /portal (Mi negocio) y sabré cuáles facturas son tuyas (te deben) y cuáles recibís (debés).'
                          ELSE '' END
    )
    FROM documentos d WHERE d.id = p_documento_id;
$$;

-- La plantilla gana la variable {{aviso_nit}} al final.
UPDATE plantillas SET cuerpo =
'✅ Leí *{{nombre_archivo}}*: {{filas}} registros{{rango}}, {{productos}} productos, {{total}} en total.{{aviso_sin_resolver}}{{aviso_nit}}

Seguí enviando archivos o escribí */listo* cuando termines.',
  variables = '["nombre_archivo","filas","rango","productos","total","aviso_sin_resolver","aviso_nit"]'::jsonb,
  version = version + 1
WHERE clave = 'ingesta.ok';
