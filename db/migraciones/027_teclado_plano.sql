-- 027_teclado_plano.sql — el teclado se aplana a un botón por fila y con tope.
--
-- No es una decisión de diseño gratuita: es el contrato que impone el nodo de
-- Telegram de n8n. `getNodeParameter` resuelve los parámetros contra la
-- descripción del nodo y descarta lo que no esté declarado, así que la FORMA del
-- teclado (cuántas filas, cuántos botones) tiene que estar literal en el
-- workflow y solo el texto y el callback_data pueden salir de una expresión.
-- Está documentado con las cinco sondas en bin/gen_wf_enviar.py.
--
-- Consecuencia: wf_enviar tiene un nodo de envío por cantidad de filas, hasta
-- MAX_FILAS. Si la base pudiera devolver un teclado más grande o con dos botones
-- en una fila, el envío lo recortaría en silencio. Se recorta ACÁ, que es donde
-- se puede ver y donde se puede cambiar de una:
--
--   * un botón por fila (en un chat una lista vertical se lee mejor que una
--     parrilla, y las etiquetas son largas);
--   * tope de 6 botones (parametros.teclado_max_filas);
--   * los botones de URL se descartan: el enviador solo sabe expresar
--     callback_data, y un botón a medio armar hace que Telegram rechace el
--     mensaje ENTERO con 400. Ninguna plantilla usa URL hoy.
--
-- Si el teclado trae más botones que el tope, se recorta y queda registrado en el
-- log del servidor: es un error de diseño de la plantilla, no algo que deba
-- pasar inadvertido.

INSERT INTO parametros (negocio_id, clave, valor)
VALUES (NULL, 'teclado_max_filas', '6'::jsonb)
ON CONFLICT (clave) WHERE negocio_id IS NULL
DO UPDATE SET valor = EXCLUDED.valor;

CREATE OR REPLACE FUNCTION teclado_markup(p_teclado jsonb, p_vars jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
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
$$;
