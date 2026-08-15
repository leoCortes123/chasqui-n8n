-- 036_cartera.sql — Fase 2: cartera. Quién me debe, a quién le debo.
--
-- Tres piezas nuevas (terceros, facturas, pagos) y una corrección al parser
-- DIAN: hoy fuerza tipo='compra' porque no sabe de qué lado de la factura está
-- el negocio. Ahora compara negocios.nit contra el NIT del emisor
-- (AccountingSupplierParty): si el emisor soy yo, es una venta y el tercero es
-- el cliente; si no, es una compra y el tercero es el proveedor. Sin NIT
-- configurado se queda en 'compra', que es el comportamiento de siempre.
--
-- La cartera REPORTA al dueño; no persigue deudores. No hay canal saliente a
-- terceros acá ni lo va a haber en esta fase.
--
-- La decisión de a quién pertenece la factura vive en UNA función
-- (cartera_facturar_dian) que trabaja sobre el XML ya guardado en documentos:
-- el parser la llama al final, y la misma función sirve para backfillear los
-- documentos DIAN que ya estaban parseados antes de esta migración sin
-- duplicar movimientos.

-- =============================================================================
-- 1. Terceros: clientes y proveedores, deduplicados por NIT
-- =============================================================================

CREATE TABLE IF NOT EXISTS terceros (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    negocio_id bigint NOT NULL REFERENCES negocios(id),
    nit        text,
    nombre     text NOT NULL,
    creado_en  timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_terceros_nit
    ON terceros(negocio_id, nit) WHERE nit IS NOT NULL;
-- Sin NIT el dedupe cae al nombre normalizado: mejor un tercero repetido que
-- mezclar dos empresas distintas por un NIT vacío.
CREATE UNIQUE INDEX IF NOT EXISTS idx_terceros_nombre
    ON terceros(negocio_id, norm_texto(nombre)) WHERE nit IS NULL;

CREATE OR REPLACE FUNCTION tercero_obtener(p_negocio_id bigint,
                                           p_nit text, p_nombre text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_nit text := nullif(btrim(coalesce(p_nit, '')), '');
    v_id  bigint;
BEGIN
    IF v_nit IS NOT NULL THEN
        SELECT id INTO v_id FROM terceros
        WHERE negocio_id = p_negocio_id AND nit = v_nit;
    ELSE
        SELECT id INTO v_id FROM terceros
        WHERE negocio_id = p_negocio_id AND nit IS NULL
          AND norm_texto(nombre) = norm_texto(p_nombre);
    END IF;

    IF v_id IS NULL THEN
        INSERT INTO terceros (negocio_id, nit, nombre)
        VALUES (p_negocio_id, v_nit, coalesce(nullif(btrim(p_nombre), ''), '(sin nombre)'))
        RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END;
$$;

-- =============================================================================
-- 2. Facturas y pagos
-- =============================================================================
-- tipo reutiliza tipo_movimiento: 'venta' = por cobrar, 'compra' = por pagar.
-- Una factura sale de exactamente un documento (el AttachedDocument trae un
-- solo Invoice), por eso documento_id es UNIQUE: re-facturar el mismo
-- documento actualiza en vez de duplicar.

CREATE TABLE IF NOT EXISTS facturas (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    negocio_id   bigint NOT NULL REFERENCES negocios(id),
    tercero_id   bigint REFERENCES terceros(id),
    documento_id bigint UNIQUE REFERENCES documentos(id),
    tipo         tipo_movimiento NOT NULL,
    numero       text,
    emision      date,
    vencimiento  date,
    total        numeric NOT NULL DEFAULT 0,
    saldo        numeric NOT NULL DEFAULT 0,
    creado_en    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_facturas_abiertas
    ON facturas(negocio_id, vencimiento) WHERE saldo > 0;

CREATE TABLE IF NOT EXISTS pagos (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    factura_id bigint NOT NULL REFERENCES facturas(id),
    fecha      date NOT NULL DEFAULT current_date,
    valor      numeric NOT NULL,
    medio      text,
    origen     text NOT NULL DEFAULT 'portal',
    usuario_id bigint REFERENCES usuarios(id),
    creado_en  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_pagos_factura ON pagos(factura_id);

-- Única puerta de escritura de pagos: el saldo nunca se toca a mano.
CREATE OR REPLACE FUNCTION pago_registrar(p_factura_id bigint, p_valor numeric,
                                          p_fecha date DEFAULT NULL,
                                          p_medio text DEFAULT NULL,
                                          p_origen text DEFAULT 'portal',
                                          p_usuario_id bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_saldo numeric;
BEGIN
    IF coalesce(p_valor, 0) <= 0 THEN
        RAISE EXCEPTION 'el pago debe ser mayor que cero' USING ERRCODE = '22023';
    END IF;

    SELECT saldo INTO v_saldo FROM facturas WHERE id = p_factura_id FOR UPDATE;
    IF v_saldo IS NULL THEN
        RAISE EXCEPTION 'no existe esa factura' USING ERRCODE = '42501';
    END IF;
    IF p_valor > v_saldo THEN
        RAISE EXCEPTION 'el pago (%) supera el saldo (%)', p_valor, v_saldo
              USING ERRCODE = '22023';
    END IF;

    INSERT INTO pagos (factura_id, fecha, valor, medio, origen, usuario_id)
    VALUES (p_factura_id, coalesce(p_fecha, current_date), p_valor,
            p_medio, p_origen, p_usuario_id);

    UPDATE facturas SET saldo = saldo - p_valor WHERE id = p_factura_id
    RETURNING saldo INTO v_saldo;

    RETURN jsonb_build_object('ok', true, 'saldo', v_saldo);
END;
$$;

-- =============================================================================
-- 3. movimientos.tercero_id
-- =============================================================================

ALTER TABLE movimientos ADD COLUMN IF NOT EXISTS
    tercero_id bigint REFERENCES terceros(id);
CREATE INDEX IF NOT EXISTS idx_mov_tercero ON movimientos(tercero_id);

-- =============================================================================
-- 4. La cabecera de la factura, desde el documento ya guardado
-- =============================================================================
-- Decide venta vs compra, crea tercero + factura y engancha los movimientos
-- del documento. Corre después del parseo de líneas y también sobre documentos
-- viejos (backfill): por eso relee el XML de documentos.contenido en vez de
-- recibir nada parseado. Solo factura raíces Invoice: una nota crédito/débito
-- ajusta consumo, no abre cartera (ese caso se analiza cuando aparezca).

CREATE OR REPLACE FUNCTION cartera_facturar_dian(p_documento_id bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_negocio_id  bigint;
    v_xml         xml;
    v_raiz        text;
    v_nit_negocio text;
    v_nit_emisor  text;
    v_nombre_emisor  text;
    v_nit_cliente    text;
    v_nombre_cliente text;
    v_tipo        tipo_movimiento;
    v_tercero_id  bigint;
    v_num         text;
    v_emision     date;
    v_vence       date;
    v_total       numeric;
    v_factura_id  bigint;
BEGIN
    SELECT d.negocio_id, convert_from(d.contenido, 'UTF8')::xml,
           nullif(btrim(coalesce(n.nit, '')), '')
      INTO v_negocio_id, v_xml, v_nit_negocio
    FROM documentos d JOIN negocios n ON n.id = d.negocio_id
    WHERE d.id = p_documento_id;

    v_raiz := (xpath('local-name(/*)', v_xml))[1]::text;
    IF v_raiz = 'AttachedDocument' THEN
        v_xml := regexp_replace(
                   regexp_replace(
                     (xpath('//*[local-name()="Attachment"]//*[local-name()="Description"]/text()', v_xml))[1]::text,
                     '^\s*<!\[CDATA\[', ''),
                   '\]\]>\s*$', '')::xml;
        v_raiz := (xpath('local-name(/*)', v_xml))[1]::text;
    END IF;

    IF v_raiz <> 'Invoice' THEN
        RETURN jsonb_build_object('documento_id', p_documento_id,
                                  'factura', false, 'motivo', v_raiz);
    END IF;

    -- Cabecera. El NIT es el CompanyID del PartyTaxScheme; el primero que
    -- aparezca bajo cada Party sirve porque DIAN lo repite idéntico.
    v_num     := (xpath('/*/*[local-name()="ID"][1]/text()', v_xml))[1]::text;
    v_emision := (xpath('/*/*[local-name()="IssueDate"][1]/text()', v_xml))[1]::text::date;
    v_vence   := coalesce(
        (xpath('/*/*[local-name()="DueDate"][1]/text()', v_xml))[1]::text::date,
        (xpath('//*[local-name()="PaymentMeans"]/*[local-name()="PaymentDueDate"][1]/text()', v_xml))[1]::text::date);
    v_total   := (xpath('//*[local-name()="LegalMonetaryTotal"]/*[local-name()="PayableAmount"]/text()', v_xml))[1]::text::numeric;

    v_nit_emisor     := (xpath('//*[local-name()="AccountingSupplierParty"]//*[local-name()="CompanyID"][1]/text()', v_xml))[1]::text;
    v_nombre_emisor  := (xpath('//*[local-name()="AccountingSupplierParty"]//*[local-name()="RegistrationName"][1]/text()', v_xml))[1]::text;
    v_nit_cliente    := (xpath('//*[local-name()="AccountingCustomerParty"]//*[local-name()="CompanyID"][1]/text()', v_xml))[1]::text;
    v_nombre_cliente := (xpath('//*[local-name()="AccountingCustomerParty"]//*[local-name()="RegistrationName"][1]/text()', v_xml))[1]::text;

    -- El lado del mostrador: emisor yo = venta al cliente; si no, compra.
    IF v_nit_negocio IS NOT NULL AND btrim(coalesce(v_nit_emisor, '')) = v_nit_negocio THEN
        v_tipo := 'venta';
        v_tercero_id := tercero_obtener(v_negocio_id, v_nit_cliente, v_nombre_cliente);
    ELSE
        v_tipo := 'compra';
        v_tercero_id := tercero_obtener(v_negocio_id, v_nit_emisor, v_nombre_emisor);
    END IF;

    INSERT INTO facturas (negocio_id, tercero_id, documento_id, tipo, numero,
                          emision, vencimiento, total, saldo)
    VALUES (v_negocio_id, v_tercero_id, p_documento_id, v_tipo, v_num,
            v_emision, v_vence, coalesce(v_total, 0), coalesce(v_total, 0))
    ON CONFLICT (documento_id) DO UPDATE
      SET tercero_id = EXCLUDED.tercero_id, tipo = EXCLUDED.tipo,
          numero = EXCLUDED.numero, emision = EXCLUDED.emision,
          vencimiento = EXCLUDED.vencimiento, total = EXCLUDED.total,
          -- el saldo conserva lo ya pagado aunque se re-facture el documento
          saldo = EXCLUDED.total - (facturas.total - facturas.saldo)
    RETURNING id INTO v_factura_id;

    UPDATE movimientos SET tercero_id = v_tercero_id, tipo = v_tipo
    WHERE documento_id = p_documento_id;

    RETURN jsonb_build_object('documento_id', p_documento_id, 'factura', true,
                              'factura_id', v_factura_id, 'tipo', v_tipo,
                              'numero', v_num, 'vencimiento', v_vence,
                              'total', v_total);
END;
$$;

-- =============================================================================
-- 5. El parser llama a la cartera al final
-- =============================================================================
-- Idéntico al de la 004 salvo el bloque marcado: tras parsear líneas y marcar
-- el documento, factura. La decisión venta/compra vive en cartera_facturar_dian
-- (que además corrige el tipo de los movimientos), no acá.

CREATE OR REPLACE FUNCTION ingesta_parsear_dian(p_documento_id bigint)
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
    v_cartera    jsonb;
BEGIN
    SELECT negocio_id, convert_from(contenido, 'UTF8')::xml
      INTO v_negocio_id, v_xml
    FROM documentos WHERE id = p_documento_id;

    v_raiz := (xpath('local-name(/*)', v_xml))[1]::text;

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

    v_num       := (xpath('/*/*[local-name()="ID"][1]/text()', v_xml))[1]::text;
    v_fecha     := (xpath('/*/*[local-name()="IssueDate"][1]/text()', v_xml))[1]::text::date;
    v_proveedor := (xpath('//*[local-name()="AccountingSupplierParty"]//*[local-name()="RegistrationName"][1]/text()', v_xml))[1]::text;
    v_payable   := (xpath('//*[local-name()="LegalMonetaryTotal"]/*[local-name()="PayableAmount"]/text()', v_xml))[1]::text::numeric;
    v_impuesto  := (xpath('(//*[local-name()="TaxTotal"]/*[local-name()="TaxAmount"])[1]/text()', v_xml))[1]::text::numeric;

    -- Líneas -> movimientos. El tipo definitivo (venta/compra) lo pone
    -- cartera_facturar_dian abajo; acá entra 'compra' como valor provisional.
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

    -- >>> Lo nuevo respecto a la 004: cartera. Si falla no tumba el parseo:
    -- los movimientos ya están y la factura se puede reconstruir después.
    BEGIN
        v_cartera := cartera_facturar_dian(p_documento_id);
    EXCEPTION WHEN OTHERS THEN
        v_cartera := jsonb_build_object('factura', false, 'error', SQLERRM);
    END;

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
        'cuadra', abs(coalesce(v_suma_lineas,0) + coalesce(v_impuesto,0) - coalesce(v_payable,0)) < 1,
        'cartera', v_cartera
    );
END;
$$;

-- =============================================================================
-- 6. Vistas de cartera
-- =============================================================================
-- Edades sobre el saldo abierto. 'al_dia' incluye facturas sin vencimiento:
-- sin fecha no se puede acusar mora.

CREATE OR REPLACE VIEW v_cartera_edades AS
SELECT negocio_id, tipo,
       CASE WHEN vencimiento IS NULL OR vencimiento >= current_date THEN 'al_dia'
            WHEN current_date - vencimiento <= 30 THEN 'd1_30'
            WHEN current_date - vencimiento <= 60 THEN 'd31_60'
            WHEN current_date - vencimiento <= 90 THEN 'd61_90'
            ELSE 'd90_mas' END AS edad,
       count(*)   AS facturas,
       sum(saldo) AS saldo
FROM facturas
WHERE saldo > 0
GROUP BY 1, 2, 3;

CREATE OR REPLACE VIEW v_cartera_tercero AS
SELECT f.negocio_id, f.tipo, t.id AS tercero_id, t.nombre, t.nit,
       count(*)           AS facturas,
       sum(f.saldo)       AS saldo,
       min(f.vencimiento) AS vencimiento_mas_antiguo,
       max(current_date - f.vencimiento) FILTER (WHERE f.vencimiento < current_date)
                          AS dias_mora
FROM facturas f JOIN terceros t ON t.id = f.tercero_id
WHERE f.saldo > 0
GROUP BY 1, 2, 3, 4, 5;

-- =============================================================================
-- 7. Backfill: los documentos DIAN que ya estaban parseados
-- =============================================================================
-- Reusa cartera_facturar_dian sobre el XML guardado: no re-parsea líneas, así
-- que no duplica movimientos. Un documento ilegible se salta y no rompe la
-- migración.

DO $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT id FROM documentos
             WHERE formato_codigo = 'dian_xml' AND estado = 'parseado' LOOP
        BEGIN
            PERFORM cartera_facturar_dian(r.id);
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'backfill cartera: documento % ilegible (%)', r.id, SQLERRM;
        END;
    END LOOP;
END;
$$;
