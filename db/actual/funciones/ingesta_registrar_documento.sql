CREATE OR REPLACE FUNCTION public.ingesta_registrar_documento(p_sesion_id bigint, p_negocio_id bigint, p_nombre_archivo text, p_mime text, p_contenido bytea)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_hash      bytea := digest(p_contenido, 'sha256');
    v_id        bigint;
    v_formato   text;
    v_ext       text := lower(split_part(p_nombre_archivo, '.', -1));
    v_op        text;
    v_duplicado boolean := false;
BEGIN
    -- Fase 1a: ¿es un documento que Postgres parsea solo? (DIAN XML)
    SELECT codigo INTO v_formato
    FROM formatos_documento
    WHERE activo AND clase = 'documento'
      AND ( lower(coalesce(p_mime,'')) = ANY(mime_patrones)
            OR v_ext = ANY(extensiones) )
    ORDER BY codigo
    LIMIT 1;

    -- Fase 1b: ¿es una tabla? El formato exacto no se sabe todavía: depende de
    -- las cabeceras, que solo n8n puede leer. Se deja formato_codigo NULL.
    IF v_formato IS NULL THEN
        v_op := (parametro(p_negocio_id, 'ingesta_extractores')) ->> v_ext;
    END IF;

    INSERT INTO documentos (sesion_id, negocio_id, formato_codigo, nombre_archivo,
                            mime, hash, contenido, tamano, estado)
    VALUES (p_sesion_id, p_negocio_id, v_formato, p_nombre_archivo,
            p_mime, v_hash, p_contenido, octet_length(p_contenido), 'pendiente')
    ON CONFLICT (negocio_id, hash) DO UPDATE SET sesion_id = EXCLUDED.sesion_id
    RETURNING id INTO v_id;

    SELECT (xmax <> 0) INTO v_duplicado FROM documentos WHERE id = v_id;

    IF v_formato IS NULL AND v_op IS NULL THEN
        RETURN ingesta_marcar_error(v_id,
                 format('no sé leer archivos %s', coalesce(nullif(v_ext,''), 'sin extensión')))
               || jsonb_build_object('documento_id', v_id, 'reconocido', false,
                                     'requiere_tabla', false);
    END IF;

    RETURN jsonb_build_object(
        'documento_id',   v_id,
        'formato',        v_formato,
        'duplicado',      v_duplicado,
        'reconocido',     true,
        -- n8n mira esto para saber si tiene que extraer la tabla primero.
        'requiere_tabla', v_formato IS NULL,
        'operacion',      v_op,
        'extension',      v_ext
    );
END;
$function$
