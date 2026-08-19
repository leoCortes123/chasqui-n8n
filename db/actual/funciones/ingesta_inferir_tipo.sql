CREATE OR REPLACE FUNCTION public.ingesta_inferir_tipo(p_documento_id bigint, p_columnas text[])
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_nombre text;
    v_cols   text;
BEGIN
    SELECT norm_texto(nombre_archivo) INTO v_nombre
    FROM documentos WHERE id = p_documento_id;

    IF coalesce(v_nombre,'') ~ '(compra|proveedor|entrada|abastec|surtido|pedido)' THEN
        RETURN 'compra';
    END IF;
    IF coalesce(v_nombre,'') ~ '(venta|salida|pos|caja|factura|ticket)' THEN
        RETURN 'venta';
    END IF;

    SELECT norm_texto(string_agg(c, ' ')) INTO v_cols FROM unnest(p_columnas) c;
    IF coalesce(v_cols,'') ~ '(proveedor|nit[ _]?prov|razon[ _]?social)' THEN
        RETURN 'compra';
    END IF;

    RETURN 'venta';
END;
$function$
