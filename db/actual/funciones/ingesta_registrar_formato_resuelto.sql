CREATE OR REPLACE FUNCTION public.ingesta_registrar_formato_resuelto(p_documento_id bigint, p_columnas text[], p_mapeo jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_huella   text := ingesta_huella(p_columnas);
    v_agregado boolean := coalesce((p_mapeo ->> 'agregado')::boolean, false);
    v_codigo   text := 'tabular_' || left(v_huella, 10);
    v_ext      text;
BEGIN
    SELECT lower(split_part(nombre_archivo, '.', -1)) INTO v_ext
    FROM documentos WHERE id = p_documento_id;

    INSERT INTO formatos_documento (codigo, nombre, mime_patrones, extensiones,
                                    funcion_parseo, deteccion, mapeo, clase,
                                    huella, origen)
    VALUES (v_codigo,
            format('Tabla %s (%s)',
                   CASE WHEN v_agregado THEN 'agregada' ELSE 'reconocida' END,
                   coalesce(nullif(v_ext,''),'?')),
            '{}', ARRAY[coalesce(nullif(v_ext,''),'csv')],
            'ingesta_cargar_tabular', '{}'::jsonb,
            jsonb_build_object(
              'tipo',          coalesce(p_mapeo ->> 'tipo', 'venta'),
              'decimal',       coalesce(p_mapeo ->> 'decimal', '.'),
              'miles',         coalesce(p_mapeo ->> 'miles', ''),
              'formato_fecha', p_mapeo ->> 'formato_fecha',
              'agregado',      v_agregado,
              'columnas',      p_mapeo -> 'columnas'),
            'tabular', v_huella, 'inferido')
    ON CONFLICT (codigo) DO UPDATE SET mapeo = EXCLUDED.mapeo
    RETURNING codigo INTO v_codigo;

    UPDATE documentos SET formato_codigo = v_codigo WHERE id = p_documento_id;

    RETURN jsonb_build_object('documento_id', p_documento_id, 'formato', v_codigo,
                              'huella', v_huella, 'agregado', v_agregado,
                              'origen', 'sql', 'nuevo', true);
END;
$function$
