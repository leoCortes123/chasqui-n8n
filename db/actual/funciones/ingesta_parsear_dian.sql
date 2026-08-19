CREATE OR REPLACE FUNCTION public.ingesta_parsear_dian(p_documento_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
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
$function$
