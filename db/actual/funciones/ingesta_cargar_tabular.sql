CREATE OR REPLACE FUNCTION public.ingesta_cargar_tabular(p_documento_id bigint, p_filas jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_mapeo jsonb;
BEGIN
    SELECT f.mapeo INTO v_mapeo
    FROM documentos d JOIN formatos_documento f ON f.codigo = d.formato_codigo
    WHERE d.id = p_documento_id;

    IF coalesce((v_mapeo ->> 'agregado')::boolean, false) THEN
        RETURN ingesta_marcar_error(p_documento_id,
                 'es un resumen (totales por día, sin producto ni cantidad), '
                 'no un detalle de movimientos: sumarlo contaría dos veces lo '
                 'que ya traen los archivos de detalle')
               || jsonb_build_object('agregado', true);
    END IF;

    RETURN ingesta_cargar_tabular_detalle(p_documento_id, p_filas);
END;
$function$
