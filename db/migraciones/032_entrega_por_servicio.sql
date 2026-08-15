-- 032_entrega_por_servicio.sql — el último mensaje y sus botones también los
-- elige la base.
--
-- wf_ejecutar entrega el informe partido en mensajes y le pone al último la
-- plantilla `ejecucion.entregada`, que trae el botón "🔄 Analizar otra vez".
-- Después de responder una pregunta de la base de conocimiento ese botón es un
-- despropósito: manda a cargar archivos.
--
-- La tentación es que el nodo decida ("si el servicio es consulta, otra
-- plantilla"). Eso sería meter en n8n exactamente lo que se saca de n8n. En vez
-- de eso, ejecucion_cerrar —que ya sabe qué servicio corrió y ya devuelve el
-- chat_id— devuelve también QUÉ plantilla usar para entregar. El workflow pasa a
-- usar el valor que le den, con el de siempre como respaldo.

INSERT INTO plantillas (clave, cuerpo, formato, variables, crudas, teclado) VALUES
('ejecucion.entregada.consulta', '{{texto}}', 'html',
 '["texto"]'::jsonb, '["texto"]'::jsonb,
 '[[{"texto":"➕ Enseñarme algo","dato":"/saber"}],
   [{"texto":"📊 Analizar mis archivos","dato":"/nueva"}]]'::jsonb)
ON CONFLICT (clave) DO UPDATE
  SET cuerpo = EXCLUDED.cuerpo, formato = EXCLUDED.formato,
      variables = EXCLUDED.variables, crudas = EXCLUDED.crudas,
      teclado = EXCLUDED.teclado, activo = true,
      version = plantillas.version + 1;

-- Idéntica a la de la 020 salvo el `plantilla_entrega` del retorno.
CREATE OR REPLACE FUNCTION ejecucion_cerrar(p_ejecucion_id bigint, p_estado text,
                                            p_resultado jsonb)
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
        SELECT u.telegram_chat_id INTO v_chat
        FROM sesiones s JOIN usuarios u ON u.id = s.usuario_id
        WHERE s.id = v_sesion_id;

        UPDATE sesiones SET
            estado     = CASE WHEN p_estado = 'completada' THEN 'completada'::estado_sesion
                              ELSE 'fallida'::estado_sesion END,
            cerrada_en = now()
        WHERE id = v_sesion_id;
    END IF;

    -- Variante por servicio si existe; si no, la de siempre.
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
