CREATE OR REPLACE FUNCTION public.ingesta_identificar_tabular(p_documento_id bigint, p_columnas text[], p_muestra jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_huella  text := ingesta_huella(p_columnas);
    v_formato text;
    v_sql     jsonb;
    v_reg     jsonb;
BEGIN
    IF v_huella IS NULL THEN
        RETURN ingesta_marcar_error(p_documento_id,
                 'el archivo no tiene cabeceras legibles')
               || jsonb_build_object('requiere_inferencia', false);
    END IF;

    -- (a) Ya la conocemos: cero trabajo.
    SELECT codigo INTO v_formato FROM formatos_documento
    WHERE activo AND clase = 'tabular' AND huella = v_huella;

    IF v_formato IS NOT NULL THEN
        UPDATE documentos SET formato_codigo = v_formato WHERE id = p_documento_id;
        RETURN jsonb_build_object('documento_id', p_documento_id,
                                  'formato', v_formato, 'huella', v_huella,
                                  'origen', 'cache',
                                  'requiere_inferencia', false);
    END IF;

    -- (b) Huella nueva: el diccionario antes que el modelo.
    v_sql := ingesta_inferir_mapeo_sql(p_documento_id, p_columnas, p_muestra);

    IF coalesce((v_sql ->> 'resuelto')::boolean, false) THEN
        v_reg := ingesta_registrar_formato_resuelto(p_documento_id, p_columnas, v_sql);
        RETURN v_reg || jsonb_build_object('huella', v_huella,
                                           'mapeo', v_sql,
                                           'requiere_inferencia', false);
    END IF;

    -- (c) Recién acá se gasta una llamada.
    RETURN jsonb_build_object('documento_id', p_documento_id, 'huella', v_huella,
                              'columnas', to_jsonb(p_columnas),
                              'motivo_inferencia', v_sql ->> 'motivo',
                              'requiere_inferencia', true);
END;
$function$
