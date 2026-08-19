CREATE OR REPLACE FUNCTION public.cartera_facturar_dian(p_documento_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
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
$function$
