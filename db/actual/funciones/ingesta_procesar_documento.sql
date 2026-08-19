CREATE OR REPLACE FUNCTION public.ingesta_procesar_documento(p_documento_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_funcion text;
    v_clase   text;
    v_result  jsonb;
BEGIN
    SELECT f.funcion_parseo, f.clase INTO v_funcion, v_clase
    FROM documentos d
    JOIN formatos_documento f ON f.codigo = d.formato_codigo
    WHERE d.id = p_documento_id AND f.activo;

    IF v_funcion IS NULL THEN
        RETURN ingesta_marcar_error(p_documento_id, 'formato no reconocido');
    END IF;

    -- Los tabulares necesitan que n8n extraiga las filas primero; el despacho
    -- antes se deducía de pg_proc.pronargs, que era adivinar.
    IF v_clase = 'tabular' THEN
        RETURN jsonb_build_object('documento_id', p_documento_id,
                                  'requiere_filas', true, 'funcion', v_funcion);
    END IF;

    BEGIN
        EXECUTE format('SELECT %I($1)', v_funcion) INTO v_result USING p_documento_id;
    EXCEPTION WHEN OTHERS THEN
        RETURN ingesta_marcar_error(p_documento_id, SQLERRM);
    END;

    RETURN v_result;
END;
$function$
