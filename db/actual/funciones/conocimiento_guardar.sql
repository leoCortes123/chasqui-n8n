CREATE OR REPLACE FUNCTION public.conocimiento_guardar(p_negocio_id bigint, p_tipo text, p_titulo text, p_contenido text DEFAULT NULL::text, p_clave text DEFAULT NULL::text, p_datos jsonb DEFAULT '{}'::jsonb, p_origen text DEFAULT 'portal'::text, p_usuario_id bigint DEFAULT NULL::bigint, p_pendiente_id bigint DEFAULT NULL::bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id bigint;
BEGIN
    IF p_clave IS NOT NULL THEN
        INSERT INTO conocimiento (negocio_id, tipo, clave, titulo, contenido,
                                  datos, origen, actualizado_por)
        VALUES (p_negocio_id, p_tipo, p_clave, p_titulo, p_contenido,
                coalesce(p_datos, '{}'::jsonb), p_origen, p_usuario_id)
        -- El índice único es parcial (solo filas con clave), así que la
        -- inferencia del ON CONFLICT tiene que repetir su predicado.
        ON CONFLICT (negocio_id, tipo, clave) WHERE clave IS NOT NULL DO UPDATE
          SET titulo = EXCLUDED.titulo, contenido = EXCLUDED.contenido,
              datos = EXCLUDED.datos, origen = EXCLUDED.origen,
              actualizado_en = now(), actualizado_por = EXCLUDED.actualizado_por,
              vigente_hasta = NULL
        RETURNING id INTO v_id;
    ELSE
        INSERT INTO conocimiento (negocio_id, tipo, titulo, contenido,
                                  datos, origen, actualizado_por)
        VALUES (p_negocio_id, p_tipo, p_titulo, p_contenido,
                coalesce(p_datos, '{}'::jsonb), p_origen, p_usuario_id)
        RETURNING id INTO v_id;
    END IF;

    -- Una pendiente se marca resuelta cuando ALGUIEN dice que este hecho la
    -- responde, nunca por parecido. Cerrarla sola con un umbral de trigramas
    -- esconde el vacío justo en la tabla que existe para mostrarlo; las
    -- coincidencias probables se sugieren en v_conocimiento_faltante, que no
    -- borra nada.
    IF p_pendiente_id IS NOT NULL THEN
        UPDATE conocimiento_pendiente
        SET resuelto_por = v_id
        WHERE id = p_pendiente_id AND negocio_id = p_negocio_id;
    END IF;

    RETURN v_id;
END;
$function$
