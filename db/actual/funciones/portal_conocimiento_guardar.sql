CREATE OR REPLACE FUNCTION public.portal_conocimiento_guardar(p_titulo text, p_tipo text DEFAULT 'faq'::text, p_contenido text DEFAULT NULL::text, p_clave text DEFAULT NULL::text, p_datos jsonb DEFAULT '{}'::jsonb, p_id bigint DEFAULT NULL::bigint, p_pendiente_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_negocio bigint := portal_negocio();
    v_usuario bigint := portal_claim('usuario_id');
    v_id      bigint;
BEGIN
    IF coalesce(btrim(p_titulo), '') = '' THEN
        RAISE EXCEPTION 'el título es obligatorio' USING ERRCODE = '22023';
    END IF;

    IF p_id IS NOT NULL THEN
        UPDATE conocimiento SET
            tipo = p_tipo, titulo = btrim(p_titulo), contenido = p_contenido,
            clave = p_clave, datos = coalesce(p_datos, '{}'::jsonb),
            actualizado_en = now(), actualizado_por = v_usuario
        WHERE id = p_id AND negocio_id = v_negocio   -- el negocio, siempre
        RETURNING id INTO v_id;

        IF v_id IS NULL THEN
            RAISE EXCEPTION 'no existe ese hecho' USING ERRCODE = '42501';
        END IF;
    ELSE
        v_id := conocimiento_guardar(v_negocio, p_tipo, btrim(p_titulo), p_contenido,
                                     p_clave, coalesce(p_datos, '{}'::jsonb),
                                     'portal', v_usuario, NULL);
    END IF;

    -- Marcar una pendiente como resuelta es explícito, nunca por parecido.
    IF p_pendiente_id IS NOT NULL THEN
        UPDATE conocimiento_pendiente SET resuelto_por = v_id
        WHERE id = p_pendiente_id AND negocio_id = v_negocio;
    END IF;

    RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$function$
