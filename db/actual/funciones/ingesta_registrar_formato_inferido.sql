CREATE OR REPLACE FUNCTION public.ingesta_registrar_formato_inferido(p_documento_id bigint, p_columnas text[], p_mapeo jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_canonicas text[] := ARRAY['fecha','producto','categoria','cantidad',
                                'valor_unitario','valor_total','codigo','unidad','impuesto'];
    v_huella  text := ingesta_huella(p_columnas);
    v_cols    jsonb := p_mapeo -> 'columnas';
    v_limpio  jsonb := '{}'::jsonb;
    v_codigo  text;
    v_ext     text;
    v_agregado boolean;
    k text; val text;
BEGIN
    IF p_mapeo ? 'error' THEN
        RETURN ingesta_marcar_error(p_documento_id,
                 format('no reconocí las columnas del archivo (%s)', p_mapeo ->> 'error'));
    END IF;

    IF v_cols IS NULL OR jsonb_typeof(v_cols) <> 'object' THEN
        RETURN ingesta_marcar_error(p_documento_id, 'no pude interpretar las columnas del archivo');
    END IF;

    -- Solo claves canónicas y solo columnas que existan en el archivo.
    FOR k, val IN SELECT * FROM jsonb_each_text(v_cols) LOOP
        IF k = ANY(v_canonicas) AND coalesce(val,'') <> ''
           AND EXISTS (SELECT 1 FROM unnest(p_columnas) c WHERE c = val) THEN
            v_limpio := v_limpio || jsonb_build_object(k, val);
        END IF;
    END LOOP;

    IF NOT (v_limpio ? 'fecha')
       OR NOT (v_limpio ? 'valor_total' OR v_limpio ? 'valor_unitario') THEN
        RETURN ingesta_marcar_error(p_documento_id,
                 'al archivo le falta la columna de fecha o la de valor');
    END IF;

    v_agregado := ingesta_es_agregado(v_limpio);

    SELECT lower(split_part(nombre_archivo, '.', -1)) INTO v_ext
    FROM documentos WHERE id = p_documento_id;

    v_codigo := 'tabular_' || left(v_huella, 10);

    INSERT INTO formatos_documento (codigo, nombre, mime_patrones, extensiones,
                                    funcion_parseo, deteccion, mapeo, clase,
                                    huella, origen)
    VALUES (v_codigo,
            format('Tabla inferida (%s)', coalesce(nullif(v_ext,''),'?')),
            '{}', ARRAY[coalesce(nullif(v_ext,''),'csv')],
            'ingesta_cargar_tabular', '{}'::jsonb,
            jsonb_build_object(
              'tipo',          coalesce(p_mapeo ->> 'tipo', 'venta'),
              'decimal',       coalesce(p_mapeo ->> 'decimal', '.'),
              'miles',         coalesce(p_mapeo ->> 'miles', ''),
              'formato_fecha', p_mapeo ->> 'formato_fecha',
              'agregado',      v_agregado,
              'columnas',      v_limpio),
            'tabular', v_huella, 'inferido')
    ON CONFLICT (codigo) DO UPDATE SET mapeo = EXCLUDED.mapeo
    RETURNING codigo INTO v_codigo;

    UPDATE documentos SET formato_codigo = v_codigo WHERE id = p_documento_id;

    RETURN jsonb_build_object('documento_id', p_documento_id, 'formato', v_codigo,
                              'huella', v_huella, 'columnas_mapeadas', v_limpio,
                              'agregado', v_agregado, 'origen', 'modelo',
                              'nuevo', true);
END;
$function$
