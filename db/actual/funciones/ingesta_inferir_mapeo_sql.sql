CREATE OR REPLACE FUNCTION public.ingesta_inferir_mapeo_sql(p_documento_id bigint, p_columnas text[], p_muestra jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_cols  jsonb := ingesta_resolver_columnas(p_columnas);
    v_dec   jsonb := ingesta_inferir_decimales(p_muestra, v_cols);
    v_fmt   text;
    v_tiene_valor boolean;
BEGIN
    v_fmt := ingesta_inferir_formato_fecha(p_muestra, v_cols ->> 'fecha');
    v_tiene_valor := (v_cols ? 'valor_total') OR (v_cols ? 'valor_unitario');

    -- Sin fecha o sin plata no hay nada que cargar. Puede ser que las columnas
    -- se llamen de un modo que el diccionario no cubre todavía: ahí sí vale
    -- gastar la llamada al modelo.
    IF NOT (v_cols ? 'fecha') OR NOT v_tiene_valor THEN
        RETURN jsonb_build_object(
            'resuelto', false,
            'motivo',   CASE WHEN NOT (v_cols ? 'fecha')
                             THEN 'no reconocí la columna de fecha'
                             ELSE 'no reconocí la columna de valor' END,
            'columnas', v_cols);
    END IF;

    RETURN jsonb_build_object(
        'resuelto',      true,
        'agregado',      ingesta_es_agregado(v_cols),
        'tipo',          ingesta_inferir_tipo(p_documento_id, p_columnas),
        'decimal',       v_dec ->> 'decimal',
        'miles',         v_dec ->> 'miles',
        'formato_fecha', v_fmt,
        'columnas',      v_cols);
END;
$function$
