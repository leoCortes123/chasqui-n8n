-- 044_whatsapp.sql — WhatsApp (Cloud API) como segundo canal sobre el MISMO
-- router. La identidad multicanal ya existía (029: identidades +
-- usuario_de_canal); lo que faltaba era que el evento pudiera declarar su canal,
-- que el envío sepa por dónde devolver, y la traducción de formato: HTML ->
-- texto de WhatsApp, teclado inline -> mensajes interactivos (botones/lista).
--
-- El wa_id de WhatsApp es el teléfono en dígitos (573001112233), así que cabe
-- en el mismo chat_id bigint que viaja por todos los sobres {chat_id,
-- respuestas[]}. Ningún workflow intermedio cambia: wf_enviar resuelve el canal
-- desde identidades al final del camino.

-- === usuario_de_canal: el evento puede declarar su canal =====================
-- El router (043) llama usuario_de_canal('telegram', evento) con el canal en
-- duro. Redefinir el router entero para pasarle el canal sería copiar cientos
-- de líneas; en cambio, el evento normalizado —que arman NUESTROS workflows,
-- no el usuario— trae `canal` y acá pisa el argumento. Sin `canal` en el
-- evento, todo sigue exactamente igual que antes.
CREATE OR REPLACE FUNCTION usuario_de_canal(p_canal text, p_evento jsonb)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_canal text   := coalesce(nullif(p_evento ->> 'canal', ''), p_canal);
    v_ext   text   := p_evento #>> '{from,id}';
    v_chat  text   := p_evento #>> '{chat,id}';
    v_user  text   := p_evento #>> '{from,username}';
    v_datos jsonb;
    v_id    bigint;
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

    RETURN v_id;
END;
$$;

-- === canal_de_chat ===========================================================
-- ¿Por dónde se le contesta a este chat_id? Se busca en identidades: tanto la
-- identidad de Telegram como la de WhatsApp guardan su chat_id en datos. Si un
-- usuario tuviera el mismo número en los dos canales (colisión teórica entre un
-- id de Telegram y un teléfono), gana el visto más recientemente. Sin identidad
-- se asume Telegram: es el comportamiento histórico y cubre a los admins viejos.
CREATE OR REPLACE FUNCTION canal_de_chat(p_chat_id bigint)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT coalesce(
        (SELECT canal FROM identidades
          WHERE datos ->> 'chat_id' = p_chat_id::text
          ORDER BY vista_en DESC LIMIT 1),
        'telegram');
$$;

-- === chat_de_usuario =========================================================
-- El chat al que se le entrega a un usuario: su identidad vista más
-- recientemente que tenga chat_id. Cae a la caché de Telegram si no hay.
CREATE OR REPLACE FUNCTION chat_de_usuario(p_usuario_id bigint)
RETURNS bigint LANGUAGE sql STABLE AS $$
    SELECT coalesce(
        (SELECT (datos ->> 'chat_id')::bigint FROM identidades
          WHERE usuario_id = p_usuario_id AND datos ? 'chat_id'
          ORDER BY vista_en DESC LIMIT 1),
        (SELECT telegram_chat_id FROM usuarios WHERE id = p_usuario_id));
$$;

-- === ejecucion_cerrar: entrega por el canal del usuario ======================
-- Igual que la versión de 032, salvo el chat de entrega: ya no lee
-- telegram_chat_id en duro sino chat_de_usuario, así el informe de un usuario
-- de WhatsApp vuelve por WhatsApp.
CREATE OR REPLACE FUNCTION ejecucion_cerrar(p_ejecucion_id bigint, p_estado text,
                                            p_resultado jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_sesion_id bigint;
    v_servicio  text;
    v_chat      bigint;
    v_plantilla text := 'ejecucion.entregada';
BEGIN
    UPDATE ejecuciones SET
        estado        = p_estado::estado_ejec,
        texto         = coalesce(p_resultado ->> 'texto', texto),
        tokens_prompt = coalesce((p_resultado ->> 'tokens_prompt')::int, tokens_prompt),
        tokens_salida = coalesce((p_resultado ->> 'tokens_salida')::int, tokens_salida),
        costo         = coalesce((p_resultado ->> 'costo')::numeric, costo),
        pdf           = coalesce(decode(p_resultado ->> 'pdf_base64', 'base64'), pdf),
        error         = p_resultado ->> 'error',
        fin           = now()
    WHERE id = p_ejecucion_id
    RETURNING sesion_id, servicio_codigo INTO v_sesion_id, v_servicio;

    IF v_sesion_id IS NOT NULL THEN
        SELECT chat_de_usuario(s.usuario_id) INTO v_chat
        FROM sesiones s WHERE s.id = v_sesion_id;

        UPDATE sesiones SET
            estado     = CASE WHEN p_estado = 'completada' THEN 'completada'::estado_sesion
                              ELSE 'fallida'::estado_sesion END,
            cerrada_en = now()
        WHERE id = v_sesion_id;
    END IF;

    IF EXISTS (SELECT 1 FROM plantillas
                WHERE clave = 'ejecucion.entregada.' || coalesce(v_servicio, '—')
                  AND activo) THEN
        v_plantilla := 'ejecucion.entregada.' || v_servicio;
    END IF;

    RETURN jsonb_build_object('ejecucion_id', p_ejecucion_id, 'estado', p_estado,
                              'chat_id', v_chat, 'servicio_codigo', v_servicio,
                              'plantilla_entrega', v_plantilla);
END;
$$;

-- === wa_texto: HTML de las plantillas -> formato de WhatsApp =================
-- Las plantillas son la fuente única y están en HTML (022). WhatsApp no parsea
-- HTML: usa *negrita*, _cursiva_, ~tachado~ y ```monoespaciado```. La
-- conversión es mecánica y vive acá, junto al resto del formato, no en un nodo.
-- Las entidades se desescapan AL FINAL y &amp; de último, para no fabricar
-- tags a partir de texto escapado.
CREATE OR REPLACE FUNCTION wa_texto(p_html text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT replace(replace(replace(
             regexp_replace(
             regexp_replace(
             regexp_replace(
             regexp_replace(
             regexp_replace(
             regexp_replace(
             regexp_replace(coalesce(p_html, ''),
               '</?(b|strong)>',        '*',        'gi'),
               '</?(i|em)>',            '_',        'gi'),
               '</?(s|strike|del)>',    '~',        'gi'),
               '</?(code|pre)>',        '```',      'gi'),
               '<a[^>]*href="([^"]*)"[^>]*>([^<]*)</a>', '\2 (\1)', 'gi'),
               '<br[^>]*>',             E'\n',      'gi'),
               '<[^>]+>',               '',         'g'),
           '&lt;', '<'), '&gt;', '>'), '&amp;', '&');
$$;

-- === wa_payload: un mensaje resuelto -> cuerpos para la Cloud API ============
-- Devuelve un ARRAY de bodies listos para POST /{phone_number_id}/messages,
-- porque un mensaje de Telegram puede necesitar DOS de WhatsApp: los mensajes
-- interactivos aceptan cuerpo de máximo 1024 caracteres, así que un texto largo
-- con botones sale como texto plano + un interactivo corto con los botones.
--
-- Mapeo del teclado (ya expandido por teclado_markup):
--   0 botones            -> mensaje de texto
--   1..3                 -> interactive "button"  (tope de la API)
--   4..10                -> interactive "list"    (tope de la API)
--   >10                  -> se recortan a 10, igual criterio que el tope de
--                           filas de Telegram: un botón que falta se ve,
--                           un 400 se lleva el mensaje entero.
--   botones con url      -> WhatsApp no los admite en button/list: la url se
--                           agrega al final del cuerpo como línea de texto.
CREATE OR REPLACE FUNCTION wa_payload(p_para text, p_texto text, p_markup jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_texto  text := coalesce(nullif(btrim(coalesce(p_texto, '')), ''), '👌');
    v_btns   jsonb := '[]'::jsonb;   -- [{id,titulo}]
    v_fila   jsonb;
    v_b      jsonb;
    v_n      int;
    v_out    jsonb := '[]'::jsonb;
    v_accion jsonb;
    v_cuerpo text;
BEGIN
    FOR v_fila IN SELECT * FROM jsonb_array_elements(coalesce(p_markup -> 'inline_keyboard', '[]'::jsonb)) LOOP
        FOR v_b IN SELECT * FROM jsonb_array_elements(v_fila) LOOP
            IF v_b ? 'url' THEN
                v_texto := v_texto || E'\n\n' || (v_b ->> 'text') || ': ' || (v_b ->> 'url');
            ELSIF coalesce(v_b ->> 'callback_data', '') <> '' THEN
                v_btns := v_btns || jsonb_build_array(jsonb_build_object(
                    'id',     left(v_b ->> 'callback_data', 200),
                    'titulo', left(v_b ->> 'text', 24)));
            END IF;
        END LOOP;
    END LOOP;

    v_btns := (SELECT coalesce(jsonb_agg(e), '[]'::jsonb)
               FROM (SELECT e FROM jsonb_array_elements(v_btns) WITH ORDINALITY AS t(e, i)
                     ORDER BY i LIMIT 10) s);
    v_n := jsonb_array_length(v_btns);

    IF v_n = 0 THEN
        RETURN jsonb_build_array(jsonb_build_object(
            'messaging_product', 'whatsapp', 'to', p_para, 'type', 'text',
            'text', jsonb_build_object('body', left(v_texto, 4096),
                                       'preview_url', true)));
    END IF;

    -- Texto largo: primero el texto plano, después un interactivo corto.
    IF length(v_texto) > 1024 THEN
        v_out := jsonb_build_array(jsonb_build_object(
            'messaging_product', 'whatsapp', 'to', p_para, 'type', 'text',
            'text', jsonb_build_object('body', left(v_texto, 4096),
                                       'preview_url', true)));
        v_cuerpo := '¿Cómo seguimos?';
    ELSE
        v_cuerpo := v_texto;
    END IF;

    IF v_n <= 3 THEN
        v_accion := jsonb_build_object('buttons',
            (SELECT jsonb_agg(jsonb_build_object('type', 'reply', 'reply',
                jsonb_build_object('id', e ->> 'id', 'title', left(e ->> 'titulo', 20))))
             FROM jsonb_array_elements(v_btns) e));
        v_out := v_out || jsonb_build_array(jsonb_build_object(
            'messaging_product', 'whatsapp', 'to', p_para, 'type', 'interactive',
            'interactive', jsonb_build_object('type', 'button',
                'body',   jsonb_build_object('text', v_cuerpo),
                'action', v_accion)));
    ELSE
        v_accion := jsonb_build_object(
            'button', 'Ver opciones',
            'sections', jsonb_build_array(jsonb_build_object('rows',
                (SELECT jsonb_agg(jsonb_build_object('id', e ->> 'id',
                                                     'title', left(e ->> 'titulo', 24)))
                 FROM jsonb_array_elements(v_btns) e))));
        v_out := v_out || jsonb_build_array(jsonb_build_object(
            'messaging_product', 'whatsapp', 'to', p_para, 'type', 'interactive',
            'interactive', jsonb_build_object('type', 'list',
                'body',   jsonb_build_object('text', v_cuerpo),
                'action', v_accion)));
    END IF;

    RETURN v_out;
END;
$$;
