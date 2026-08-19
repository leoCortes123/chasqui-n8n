CREATE OR REPLACE FUNCTION public.wa_payload(p_para text, p_texto text, p_markup jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
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
$function$
