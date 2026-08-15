-- 004_ingesta.sql — registro y parseo de documentos.
-- n8n nunca escribe INSERTs: llama a estas funciones. El despacho por tipo
-- ocurre aquí dentro, no en un nodo con condicionales.

-- === Normalización de texto (compartida con matching) ======================
-- minúsculas, sin acentos, sin dobles espacios. IMMUTABLE para poder indexar.
CREATE FUNCTION norm_texto(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT btrim(regexp_replace(lower(unaccent(coalesce(p, ''))), '\s+', ' ', 'g'));
$$;

-- === Registro de documento (idempotente por hash) =========================
-- Recibe el archivo crudo. Si el mismo negocio ya lo subió, devuelve el
-- existente sin duplicar: un retry de n8n sobre esta función es seguro.
CREATE FUNCTION ingesta_registrar_documento(
    p_sesion_id      bigint,
    p_negocio_id     bigint,
    p_nombre_archivo text,
    p_mime           text,
    p_contenido      bytea
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_hash      bytea := digest(p_contenido, 'sha256');
    v_id        bigint;
    v_formato   text;
    v_duplicado boolean := false;
BEGIN
    -- Detección de formato por extensión/mime contra formatos_documento.
    SELECT codigo INTO v_formato
    FROM formatos_documento
    WHERE activo
      AND (
        lower(coalesce(p_mime,'')) = ANY(mime_patrones)
        OR lower(split_part(p_nombre_archivo, '.', -1)) = ANY(extensiones)
      )
    ORDER BY codigo
    LIMIT 1;

    INSERT INTO documentos (sesion_id, negocio_id, formato_codigo, nombre_archivo,
                            mime, hash, contenido, tamano, estado)
    VALUES (p_sesion_id, p_negocio_id, v_formato, p_nombre_archivo,
            p_mime, v_hash, p_contenido, octet_length(p_contenido), 'pendiente')
    ON CONFLICT (negocio_id, hash) DO UPDATE SET sesion_id = EXCLUDED.sesion_id
    RETURNING id INTO v_id;

    SELECT (xmax <> 0) INTO v_duplicado FROM documentos WHERE id = v_id;

    RETURN jsonb_build_object(
        'documento_id', v_id,
        'formato', v_formato,
        'duplicado', v_duplicado,
        'reconocido', v_formato IS NOT NULL
    );
END;
$$;

-- === Despacho de parseo ====================================================
-- Mira formatos_documento.funcion_parseo y la ejecuta. wf_ingesta llama solo
-- a esta: un formato nuevo no añade un nodo, añade una fila + su función.
CREATE FUNCTION ingesta_procesar_documento(p_documento_id bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_funcion text;
    v_nargs   int;
    v_result  jsonb;
BEGIN
    SELECT f.funcion_parseo INTO v_funcion
    FROM documentos d
    JOIN formatos_documento f ON f.codigo = d.formato_codigo
    WHERE d.id = p_documento_id AND f.activo;

    IF v_funcion IS NULL THEN
        RETURN ingesta_marcar_error(p_documento_id, 'formato no reconocido');
    END IF;

    -- Algunos parsers (tabulares) necesitan las filas ya convertidas por el
    -- nodo CSV de n8n, así que reciben 2 argumentos y no se pueden despachar
    -- solo desde el bytea. En ese caso se avisa a wf_ingesta para que enrute
    -- por el nodo CSV y llame a la función directamente. Sin trampa silenciosa.
    SELECT pronargs INTO v_nargs FROM pg_proc WHERE proname = v_funcion LIMIT 1;
    IF coalesce(v_nargs, 1) > 1 THEN
        RETURN jsonb_build_object('documento_id', p_documento_id,
                                  'requiere_filas', true, 'funcion', v_funcion);
    END IF;

    -- Un archivo malo no debe tumbar la sesión: se captura y se marca solo él.
    BEGIN
        EXECUTE format('SELECT %I($1)', v_funcion)
          INTO v_result USING p_documento_id;
    EXCEPTION WHEN OTHERS THEN
        RETURN ingesta_marcar_error(p_documento_id, SQLERRM);
    END;

    RETURN v_result;
END;
$$;

CREATE FUNCTION ingesta_marcar_error(p_documento_id bigint, p_error text)
RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
    UPDATE documentos SET estado = 'error', error = p_error WHERE id = p_documento_id;
    RETURN jsonb_build_object('documento_id', p_documento_id, 'estado', 'error', 'error', p_error);
END;
$$;

-- === Parser DIAN (UBL 2.1) =================================================
-- Desenvuelve AttachedDocument (Invoice embebido como CDATA), luego lee
-- cabecera, totales de control y líneas con XMLTABLE. Sirve a Invoice,
-- CreditNote y DebitNote parametrizando el nombre de la línea.
CREATE FUNCTION ingesta_parsear_dian(p_documento_id bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_negocio_id bigint;
    v_xml        xml;
    v_raiz       text;
    v_linea_tag  text;
    v_num        text;
    v_fecha      date;
    v_proveedor  text;
    v_payable    numeric;
    v_impuesto   numeric;
    v_suma_lineas numeric;
    v_n_lineas   int;
BEGIN
    SELECT negocio_id, convert_from(contenido, 'UTF8')::xml
      INTO v_negocio_id, v_xml
    FROM documentos WHERE id = p_documento_id;

    v_raiz := (xpath('local-name(/*)', v_xml))[1]::text;

    -- AttachedDocument: el Invoice real va en CDATA dentro de Attachment.
    IF v_raiz = 'AttachedDocument' THEN
        v_xml := regexp_replace(
                   regexp_replace(
                     (xpath('//*[local-name()="Attachment"]//*[local-name()="Description"]/text()', v_xml))[1]::text,
                     '^\s*<!\[CDATA\[', ''),
                   '\]\]>\s*$', '')::xml;
        v_raiz := (xpath('local-name(/*)', v_xml))[1]::text;
    END IF;

    v_linea_tag := CASE v_raiz
                     WHEN 'Invoice'    THEN 'InvoiceLine'
                     WHEN 'CreditNote' THEN 'CreditNoteLine'
                     WHEN 'DebitNote'  THEN 'DebitNoteLine'
                     ELSE NULL END;

    IF v_linea_tag IS NULL THEN
        RETURN ingesta_marcar_error(p_documento_id,
                 format('raíz UBL no soportada: %s', v_raiz));
    END IF;

    -- Cabecera y controles. local-name() evita pelear con los namespaces.
    v_num       := (xpath('/*/*[local-name()="ID"][1]/text()', v_xml))[1]::text;
    v_fecha     := (xpath('/*/*[local-name()="IssueDate"][1]/text()', v_xml))[1]::text::date;
    v_proveedor := (xpath('//*[local-name()="AccountingSupplierParty"]//*[local-name()="RegistrationName"][1]/text()', v_xml))[1]::text;
    v_payable   := (xpath('//*[local-name()="LegalMonetaryTotal"]/*[local-name()="PayableAmount"]/text()', v_xml))[1]::text::numeric;
    v_impuesto  := (xpath('(//*[local-name()="TaxTotal"]/*[local-name()="TaxAmount"])[1]/text()', v_xml))[1]::text::numeric;

    -- Líneas -> movimientos tipo compra. El producto se resolverá en matching.
    WITH lineas AS (
        SELECT * FROM XMLTABLE(
            XMLNAMESPACES(
                'urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2' AS cac,
                'urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2'     AS cbc),
            ('/*/cac:' || v_linea_tag) PASSING v_xml
            COLUMNS
                descripcion text    PATH 'cac:Item/cbc:Description',
                codigo      text    PATH 'cac:Item/cac:StandardItemIdentification/cbc:ID',
                cantidad    numeric PATH '(cbc:InvoicedQuantity|cbc:CreditedQuantity|cbc:DebitedQuantity)',
                unidad      text    PATH '(cbc:InvoicedQuantity|cbc:CreditedQuantity|cbc:DebitedQuantity)/@unitCode',
                total_linea numeric PATH 'cbc:LineExtensionAmount',
                precio      numeric PATH 'cac:Price/cbc:PriceAmount'
        )
    ),
    ins AS (
        INSERT INTO movimientos (negocio_id, documento_id, tipo, fecha,
                                 cantidad, valor_unitario, valor_total, raw)
        SELECT v_negocio_id, p_documento_id, 'compra', v_fecha,
               l.cantidad,
               coalesce(l.precio, CASE WHEN l.cantidad > 0 THEN l.total_linea / l.cantidad END),
               l.total_linea,
               jsonb_build_object('descripcion', l.descripcion, 'codigo', l.codigo,
                                  'unidad', l.unidad, 'proveedor', v_proveedor)
        FROM lineas l
        RETURNING valor_total
    )
    SELECT count(*), coalesce(sum(valor_total), 0) INTO v_n_lineas, v_suma_lineas FROM ins;

    IF v_n_lineas = 0 THEN
        RETURN ingesta_marcar_error(p_documento_id, 'factura sin líneas legibles');
    END IF;

    UPDATE documentos SET estado = 'parseado', error = NULL WHERE id = p_documento_id;

    RETURN jsonb_build_object(
        'documento_id', p_documento_id,
        'estado', 'parseado',
        'tipo_ubl', v_raiz,
        'numero', v_num,
        'proveedor', v_proveedor,
        'lineas', v_n_lineas,
        'suma_lineas', v_suma_lineas,
        'total_control', v_payable,
        'impuesto', v_impuesto,
        -- el llamador compara: suma de líneas + impuesto vs total de control
        'cuadra', abs(coalesce(v_suma_lineas,0) + coalesce(v_impuesto,0) - coalesce(v_payable,0)) < 1
    );
END;
$$;

-- === Parser tabular genérico (CSV de POS) ==================================
-- No parsea el archivo crudo: recibe las filas ya convertidas a jsonb por
-- n8n (que sí tiene un buen nodo de CSV) y las mapea a movimientos según
-- formatos_documento.mapeo. Un POS nuevo = otro mapeo, no otra función.
CREATE FUNCTION ingesta_cargar_tabular(p_documento_id bigint, p_filas jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_negocio_id bigint;
    v_mapeo      jsonb;
    v_cols       jsonb;
    v_tipo       text;
    v_n          int;
BEGIN
    SELECT d.negocio_id, f.mapeo
      INTO v_negocio_id, v_mapeo
    FROM documentos d JOIN formatos_documento f ON f.codigo = d.formato_codigo
    WHERE d.id = p_documento_id;

    v_cols := v_mapeo -> 'columnas';
    v_tipo := coalesce(v_mapeo ->> 'tipo', 'venta');

    WITH filas AS (SELECT jsonb_array_elements(p_filas) AS r),
    ins AS (
        INSERT INTO movimientos (negocio_id, documento_id, tipo, fecha,
                                 cantidad, valor_unitario, valor_total, raw)
        SELECT v_negocio_id, p_documento_id, v_tipo::tipo_movimiento,
               nullif(r ->> (v_cols ->> 'fecha'), '')::date,
               nullif(r ->> (v_cols ->> 'cantidad'), '')::numeric,
               nullif(r ->> (v_cols ->> 'valor_unitario'), '')::numeric,
               nullif(r ->> (v_cols ->> 'valor_total'), '')::numeric,
               r
        FROM filas
        RETURNING 1
    )
    SELECT count(*) INTO v_n FROM ins;

    UPDATE documentos SET estado = 'parseado', error = NULL WHERE id = p_documento_id;

    RETURN jsonb_build_object('documento_id', p_documento_id, 'estado', 'parseado',
                              'filas', v_n, 'tipo', v_tipo);
END;
$$;
