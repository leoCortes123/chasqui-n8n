-- 050_negocio_automatico.sql — un usuario sin negocio no puede cargar nada.
--
-- Nadie creaba la fila de `negocios`: los que había se habían insertado a mano.
-- Un usuario nuevo (o cualquiera después de limpiar_datos.sql) quedaba con
-- `usuarios.negocio_id` NULL, la sesión nacía con `negocio_id` NULL y CADA
-- archivo moría en el INSERT de `documentos` con "null value in column
-- negocio_id violates not-null constraint".
--
-- Lo peor no es el error: es que era MUDO. El nodo Registrar de wf_ingesta
-- aborta el workflow, el usuario manda cinco archivos, no le contesta nadie, y
-- cuando toca Analizar le dice "no cargaste ninguno".
--
-- El negocio ahora se crea solo, en `usuario_de_canal`, que corre en cada
-- mensaje entrante: eso cubre al usuario nuevo Y al viejo que quedó sin
-- negocio. El nombre es un marcador ('Mi negocio'); el real lo pone el dueño en
-- el portal. El `tipo` sigue en NULL a propósito: router_arranque_servicio lo
-- pregunta con botones apenas se elige un servicio.

-- === usuario_de_canal (copia de la 044 + asegurar el negocio al final) =======
CREATE OR REPLACE FUNCTION usuario_de_canal(p_canal text, p_evento jsonb)
RETURNS bigint LANGUAGE plpgsql AS $$
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
$$;

-- === Backfill ===============================================================
-- Los usuarios que ya existen sin negocio no tienen que esperar a escribir un
-- mensaje para quedar utilizables.
DO $$
DECLARE r record; v_neg bigint;
BEGIN
    FOR r IN SELECT id FROM usuarios WHERE negocio_id IS NULL LOOP
        INSERT INTO negocios (nombre) VALUES ('Mi negocio') RETURNING id INTO v_neg;
        UPDATE usuarios SET negocio_id = v_neg WHERE id = r.id;
        UPDATE sesiones SET negocio_id = v_neg
         WHERE usuario_id = r.id AND negocio_id IS NULL;
    END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';
