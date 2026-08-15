-- 022_plantillas_html.sql — los mensajes pasan a HTML y las variables se escapan.
--
-- El bug: el informe se generaba, se guardaba y nunca llegaba al chat. Telegram
-- devolvía 400 y el `onError: continueRegularOutput` de EnviarTexto lo
-- convertía en "éxito", así que no quedaba rastro en ningún lado:
--
--   Bad Request: can't parse entities: Can't find end of the entity
--   starting at byte offset 27
--
-- El offset 27 cae justo en "ventas_compras". El nodo de Telegram de n8n fuerza
-- Markdown cuando no se le pide otra cosa (GenericFunctions.js):
--
--   if (!additionalFields.parse_mode) { additionalFields.parse_mode = 'Markdown'; }
--
-- O sea que NO existe el modo "texto plano": todo mensaje pasa por un parser de
-- entidades. Y el guion bajo de un código de servicio abre una cursiva que nunca
-- cierra. Los mensajes cortos zafaban de casualidad, por tener los asteriscos
-- balanceados.
--
-- Se pasa a HTML, que es el único modo con una regla de escape simple y
-- definida (tres caracteres) frente a los ~18 de MarkdownV2 y al escape
-- inservible del Markdown legacy.
--
-- La regla queda: el CUERPO de la plantilla es confiable y puede traer <b>;
-- los VALORES de las variables no lo son —vienen del modelo, del nombre de un
-- archivo o de un texto de error— y se escapan siempre. Así ningún contenido
-- ajeno puede volver a romper el envío.

CREATE OR REPLACE FUNCTION resolver_plantilla(p_clave text, p_vars jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cuerpo  text;
    v_formato text;
    v_vars    jsonb;
    k text; val text;
BEGIN
    v_vars := CASE WHEN jsonb_typeof(p_vars) = 'object' THEN p_vars ELSE '{}'::jsonb END;

    SELECT cuerpo, formato INTO v_cuerpo, v_formato
    FROM plantillas WHERE clave = p_clave AND activo LIMIT 1;

    IF v_cuerpo IS NULL THEN
        -- Degradación: sin plantilla se manda la clave como texto. Eso es
        -- contenido arbitrario (así entregan su salida los comandos de admin),
        -- así que acá SÍ se escapa.
        v_cuerpo := replace(replace(replace(p_clave, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
        v_formato := 'html';
    END IF;

    FOR k, val IN SELECT * FROM jsonb_each_text(v_vars) LOOP
        v_cuerpo := replace(v_cuerpo, '{{' || k || '}}',
                      replace(replace(replace(coalesce(val, ''),
                        '&', '&amp;'), '<', '&lt;'), '>', '&gt;'));
    END LOOP;

    RETURN jsonb_build_object('texto', v_cuerpo, 'formato', v_formato);
END;
$$;

-- Los cuerpos venían con *negrita* de Markdown, que en modo HTML se vería como
-- asteriscos literales. Se convierten de una en todas las plantillas.
UPDATE plantillas
SET cuerpo  = regexp_replace(cuerpo, '\*([^*\n]+)\*', '<b>\1</b>', 'g'),
    formato = 'html',
    version = version + 1
WHERE cuerpo ~ '\*[^*\n]+\*';

UPDATE plantillas SET formato = 'html' WHERE formato <> 'html';
