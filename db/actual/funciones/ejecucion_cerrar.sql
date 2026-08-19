CREATE OR REPLACE FUNCTION public.ejecucion_cerrar(p_ejecucion_id bigint, p_estado text, p_resultado jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_sesion_id  bigint;
    v_servicio   text;
    v_negocio_id bigint;
    v_chat       bigint;
    v_plantilla  text := 'ejecucion.entregada';
    v_snapshot   bigint;
    v_recos      jsonb;
    v_medido     jsonb;
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
    RETURNING sesion_id, servicio_codigo, negocio_id
         INTO v_sesion_id, v_servicio, v_negocio_id;

    IF v_sesion_id IS NOT NULL THEN
        SELECT chat_de_usuario(s.usuario_id) INTO v_chat
        FROM sesiones s WHERE s.id = v_sesion_id;

        UPDATE sesiones SET
            estado     = CASE WHEN p_estado = 'completada' THEN 'completada'::estado_sesion
                              ELSE 'fallida'::estado_sesion END,
            cerrada_en = now()
        WHERE id = v_sesion_id;
    END IF;

    IF p_estado = 'completada' AND v_negocio_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM servicios
                    WHERE codigo = v_servicio AND entrada = 'archivos') THEN
        -- >>> 058: la memoria del estado del negocio.
        BEGIN
            v_snapshot := snapshot_tomar(v_negocio_id, 'ejecucion', p_ejecucion_id);
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO fallas (workflow, ejecucion_id, sesion_id, tipo, transitoria, detalle)
            VALUES ('snapshot_tomar', p_ejecucion_id, v_sesion_id, 'permanente', false,
                    jsonb_build_object('mensaje', SQLERRM, 'sqlstate', SQLSTATE));
        END;

        -- >>> 059: la memoria de lo que se le recomendó (R-III).
        BEGIN
            v_recos := recomendaciones_registrar(v_negocio_id, p_ejecucion_id);
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO fallas (workflow, ejecucion_id, sesion_id, tipo, transitoria, detalle)
            VALUES ('recomendaciones_registrar', p_ejecucion_id, v_sesion_id,
                    'permanente', false,
                    jsonb_build_object('mensaje', SQLERRM, 'sqlstate', SQLSTATE));
        END;

        -- >>> 066: ¿sirvió lo que se recomendó antes? Va DESPUÉS del registro
        -- porque el registro es el que cierra por dato, y lo que acaba de
        -- cerrarse ya puede empezar a medirse en la corrida siguiente.
        BEGIN
            v_medido := recomendaciones_medir(v_negocio_id);
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO fallas (workflow, ejecucion_id, sesion_id, tipo, transitoria, detalle)
            VALUES ('recomendaciones_medir', p_ejecucion_id, v_sesion_id,
                    'permanente', false,
                    jsonb_build_object('mensaje', SQLERRM, 'sqlstate', SQLSTATE));
        END;
    END IF;

    IF EXISTS (SELECT 1 FROM plantillas
                WHERE clave = 'ejecucion.entregada.' || coalesce(v_servicio, '—')
                  AND activo) THEN
        v_plantilla := 'ejecucion.entregada.' || v_servicio;
    END IF;

    RETURN jsonb_build_object('ejecucion_id', p_ejecucion_id, 'estado', p_estado,
                              'chat_id', v_chat, 'servicio_codigo', v_servicio,
                              'plantilla_entrega', v_plantilla,
                              'snapshot_id', v_snapshot,
                              'recomendaciones', v_recos,
                              'resultados', v_medido);
END;
$function$
