CREATE OR REPLACE FUNCTION public.router_h_recibiendo(p_ctx jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_chat_id    bigint  := (p_ctx ->> 'chat_id')::bigint;
    v_cmd        text    := p_ctx ->> 'cmd';
    v_tiene_doc  boolean := (p_ctx ->> 'tiene_doc')::boolean;
    v_ses_id     bigint  := (p_ctx ->> 'sesion_id')::bigint;
    v_ses_srv    text    := p_ctx ->> 'sesion_servicio';
    v_ev         jsonb;
BEGIN
    IF v_tiene_doc THEN
        RETURN router_respuesta(v_chat_id, NULL, NULL, NULL,
                 jsonb_build_array(jsonb_build_object(
                   'tipo','ingerir','sesion_id', v_ses_id)));
    END IF;

    IF v_cmd = 'svc' THEN
        RETURN router_respuesta(v_chat_id, 'sistema.servicio_ya_elegido',
                 jsonb_build_object('servicio',
                   (SELECT nombre FROM servicios WHERE codigo = v_ses_srv)));
    END IF;

    -- /todos y /faltan quedaron sin uso: el panel dice todo el tiempo lo que la
    -- pregunta preguntaba una vez. Se siguen aceptando porque puede haber un
    -- teclado viejo en el chat de alguien, y contestan con el panel.
    IF v_cmd IN ('/todos','/faltan') THEN
        RETURN jsonb_build_object('chat_id', v_chat_id, 'respuestas', '[]'::jsonb,
                 'acciones', jsonb_build_array(jsonb_build_object(
                   'tipo','panel','sesion_id', v_ses_id)));
    END IF;

    IF v_cmd IN ('/listo','/analizar','/fin') THEN
        IF NOT carga_hay_con_que(v_ses_id) THEN
            RETURN router_respuesta(v_chat_id, 'sistema.sin_documentos');
        END IF;

        -- El botón deja la marca y NO arranca. Si ya hubo silencio suficiente,
        -- carga_evaluar arranca en la misma llamada; si todavía están llegando
        -- archivos, el panel pasa a "esperando" y arranca el debounce del último
        -- que entre. Esta es la línea que perdió los 38 archivos.
        UPDATE sesiones SET analisis_pedido_en = now() WHERE id = v_ses_id;

        v_ev := carga_evaluar(v_ses_id);
        IF v_ev ->> 'accion' = 'analizar' THEN
            RETURN jsonb_build_object('chat_id', v_chat_id, 'respuestas', '[]'::jsonb,
                     'acciones', jsonb_build_array(
                       jsonb_build_object('tipo','panel','sesion_id', v_ses_id,
                                          'modo','analizando'),
                       jsonb_build_object('tipo','ejecutar',
                                          'ejecucion_id', (v_ev ->> 'ejecucion_id')::bigint)));
        END IF;

        RETURN jsonb_build_object('chat_id', v_chat_id, 'respuestas', '[]'::jsonb,
                 'acciones', jsonb_build_array(jsonb_build_object(
                   'tipo','panel','sesion_id', v_ses_id, 'modo','esperando')));
    END IF;

    RETURN router_respuesta(v_chat_id, 'sistema.esperando_listo');
END;
$function$
