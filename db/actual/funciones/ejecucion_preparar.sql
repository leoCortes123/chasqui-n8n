CREATE OR REPLACE FUNCTION public.ejecucion_preparar(p_ejecucion_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_negocio_id bigint;
    v_servicio   text;
    v_sesion_id  bigint;
    v_contexto   jsonb;
    v_funcion    text;
    v_cupo       bigint;
    v_usados     bigint;
    v_hallazgos  jsonb;
    v_prompt     record;
BEGIN
    SELECT negocio_id, servicio_codigo, sesion_id
      INTO v_negocio_id, v_servicio, v_sesion_id
    FROM ejecuciones WHERE id = p_ejecucion_id;

    -- Control de cupo.
    SELECT cupo_tokens_mes, tokens_mes INTO v_cupo, v_usados
    FROM v_consumo_negocio WHERE negocio_id = v_negocio_id;

    IF v_cupo IS NOT NULL AND v_cupo > 0 AND v_usados >= v_cupo THEN
        UPDATE ejecuciones SET estado = 'bloqueada',
               error = 'cupo mensual superado', fin = now()
        WHERE id = p_ejecucion_id;
        RETURN jsonb_build_object('bloqueado', true, 'limite', v_cupo, 'usados', v_usados);
    END IF;

    SELECT coalesce(contexto, '{}'::jsonb) INTO v_contexto
    FROM sesiones WHERE id = v_sesion_id;
    v_contexto := coalesce(v_contexto, '{}'::jsonb);

    SELECT funcion_hallazgos INTO v_funcion FROM servicios WHERE codigo = v_servicio;

    IF to_regprocedure(format('%I(bigint,jsonb)', coalesce(v_funcion, ''))) IS NULL THEN
        UPDATE ejecuciones SET estado = 'fallida',
               error = format('servicio %s: función de hallazgos inexistente (%s)',
                              v_servicio, coalesce(v_funcion, '—')), fin = now()
        WHERE id = p_ejecucion_id;
        RETURN jsonb_build_object('bloqueado', false, 'error', 'sin_funcion_hallazgos');
    END IF;

    EXECUTE format('SELECT %I($1, $2)', v_funcion)
       INTO v_hallazgos USING v_negocio_id, v_contexto;

    SELECT id, sistema, usuario, modelo, temperatura, max_tokens
      INTO v_prompt
    FROM prompts WHERE servicio_codigo = v_servicio AND activo LIMIT 1;

    IF v_prompt.id IS NULL THEN
        UPDATE ejecuciones SET estado = 'fallida',
               error = format('sin prompt activo para %s', v_servicio), fin = now()
        WHERE id = p_ejecucion_id;
        RETURN jsonb_build_object('bloqueado', false, 'error', 'sin_prompt');
    END IF;

    UPDATE ejecuciones
    SET hallazgos = v_hallazgos, prompt_id = v_prompt.id, estado = 'procesando'
    WHERE id = p_ejecucion_id;

    RETURN jsonb_build_object(
        'bloqueado', false,
        'ejecucion_id', p_ejecucion_id,
        'hallazgos', v_hallazgos,
        'prompt', jsonb_build_object(
            'id', v_prompt.id, 'sistema', v_prompt.sistema, 'usuario', v_prompt.usuario,
            'modelo', v_prompt.modelo, 'temperatura', v_prompt.temperatura,
            'max_tokens', v_prompt.max_tokens)
    );
END;
$function$
