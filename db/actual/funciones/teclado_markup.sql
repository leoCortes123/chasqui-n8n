CREATE OR REPLACE FUNCTION public.teclado_markup(p_teclado jsonb, p_vars jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_max   int := coalesce((parametro(NULL, 'teclado_max_filas'))::text::int, 6);
    v_filas jsonb := '[]'::jsonb;
    v_fila  jsonb;
    v_b     jsonb;
    v_vars  jsonb;
    v_texto text;
    v_dato  text;
    v_total int := 0;
    k text; val text;
BEGIN
    IF p_teclado IS NULL OR jsonb_typeof(p_teclado) <> 'array' THEN
        RETURN jsonb_build_object('inline_keyboard', '[]'::jsonb);
    END IF;
    v_vars := CASE WHEN jsonb_typeof(p_vars) = 'object' THEN p_vars ELSE '{}'::jsonb END;

    FOR v_fila IN SELECT * FROM jsonb_array_elements(p_teclado) LOOP
        CONTINUE WHEN jsonb_typeof(v_fila) <> 'array';

        FOR v_b IN SELECT * FROM jsonb_array_elements(v_fila) LOOP
            CONTINUE WHEN jsonb_typeof(v_b) <> 'object';
            v_total := v_total + 1;

            v_texto := v_b ->> 'texto';
            v_dato  := v_b ->> 'dato';
            CONTINUE WHEN v_texto IS NULL;
            -- Sin callback_data no hay botón posible (Telegram: "Text buttons
            -- are unallowed in the inline keyboard").
            CONTINUE WHEN coalesce(v_dato, '') = '';

            FOR k, val IN SELECT * FROM jsonb_each_text(v_vars) LOOP
                v_texto := replace(v_texto, '{{' || k || '}}', coalesce(val, ''));
                v_dato  := replace(v_dato,  '{{' || k || '}}', coalesce(val, ''));
            END LOOP;

            EXIT WHEN jsonb_array_length(v_filas) >= v_max;
            -- Cada botón, su propia fila.
            -- callback_data: 1..64 bytes. Se recorta en vez de reventar; un botón
            -- que no responde se ve, un 400 se lleva todo el mensaje.
            v_filas := v_filas || jsonb_build_array(jsonb_build_array(
                jsonb_build_object('text', v_texto, 'callback_data', left(v_dato, 64))));
        END LOOP;

        EXIT WHEN jsonb_array_length(v_filas) >= v_max;
    END LOOP;

    IF v_total > v_max THEN
        RAISE WARNING 'teclado_markup: % botones para un tope de %; se recortó',
                      v_total, v_max;
    END IF;

    RETURN jsonb_build_object('inline_keyboard', v_filas);
END;
$function$
