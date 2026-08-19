CREATE OR REPLACE FUNCTION public.usuario_de_canal(p_canal text, p_evento jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_canal text   := coalesce(nullif(p_evento ->> 'canal', ''), p_canal);
    v_ext   text   := p_evento #>> '{from,id}';
    v_chat  text   := p_evento #>> '{chat,id}';
    v_user  text   := p_evento #>> '{from,username}';
    v_datos jsonb;
    v_id    bigint;
    v_neg   bigint;
BEGIN
    IF v_ext IS NULL OR btrim(v_ext) = '' THEN
        RAISE EXCEPTION 'usuario_de_canal(%): el evento no trae from.id', v_canal;
    END IF;

    v_datos := jsonb_strip_nulls(jsonb_build_object(
                 'chat_id', v_chat, 'username', v_user));

    SELECT usuario_id INTO v_id FROM identidades
    WHERE canal = v_canal AND id_externo = v_ext;

    IF v_id IS NULL THEN
        INSERT INTO usuarios (telegram_user_id, telegram_chat_id, telegram_username)
        VALUES (CASE WHEN v_canal = 'telegram' THEN v_ext::bigint END,
                CASE WHEN v_canal = 'telegram' THEN v_chat::bigint END,
                CASE WHEN v_canal = 'telegram' THEN v_user END)
        RETURNING id INTO v_id;

        INSERT INTO identidades (canal, id_externo, usuario_id, datos)
        VALUES (v_canal, v_ext, v_id, v_datos)
        ON CONFLICT (canal, id_externo)
          DO UPDATE SET vista_en = now(), datos = identidades.datos || EXCLUDED.datos
        RETURNING usuario_id INTO v_id;
    ELSE
        UPDATE identidades SET vista_en = now(), datos = datos || v_datos
        WHERE canal = v_canal AND id_externo = v_ext;
    END IF;

    IF v_canal = 'telegram' THEN
        UPDATE usuarios SET
            telegram_chat_id  = coalesce(v_chat::bigint, telegram_chat_id),
            telegram_username = coalesce(v_user, telegram_username)
        WHERE id = v_id;
    END IF;

    -- Todo usuario tiene su negocio. Sin esto no hay dónde guardar un solo
    -- movimiento y la carga de archivos falla en silencio.
    SELECT negocio_id INTO v_neg FROM usuarios WHERE id = v_id;
    IF v_neg IS NULL THEN
        INSERT INTO negocios (nombre) VALUES ('Mi negocio') RETURNING id INTO v_neg;
        UPDATE usuarios SET negocio_id = v_neg WHERE id = v_id;
        -- Una sesión abierta antes de tener negocio también se repara: si no,
        -- los archivos de ESTA conversación siguen sin destino.
        UPDATE sesiones SET negocio_id = v_neg
         WHERE usuario_id = v_id AND negocio_id IS NULL AND cerrada_en IS NULL;
    END IF;

    RETURN v_id;
END;
$function$
