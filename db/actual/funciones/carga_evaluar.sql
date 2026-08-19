CREATE OR REPLACE FUNCTION public.carga_evaluar(p_sesion_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_ses      record;
    v_res      jsonb;
    v_silencio int := coalesce(
        (parametro(NULL, 'carga_silencio_segundos'))::text::int, 10);
    v_ultimo   timestamptz;
    v_ejec_id  bigint;
BEGIN
    SELECT * INTO v_ses FROM sesiones WHERE id = p_sesion_id;
    IF v_ses.id IS NULL OR v_ses.cerrada_en IS NOT NULL THEN
        RETURN jsonb_build_object('accion', 'nada');
    END IF;

    v_res    := carga_resumen(p_sesion_id);
    v_ultimo := (v_res ->> 'ultimo_en')::timestamptz;

    -- Todavía están llegando: el que entre después se encarga.
    IF v_ultimo IS NOT NULL AND now() - v_ultimo < make_interval(secs => v_silencio) THEN
        RETURN jsonb_build_object('accion', 'nada');
    END IF;

    -- Silencio, y el botón ya estaba tocado.
    IF v_ses.analisis_pedido_en IS NOT NULL AND v_ses.estado = 'recibiendo' THEN
        IF NOT carga_hay_con_que(p_sesion_id) THEN
            RETURN jsonb_build_object('accion', 'panel',
                     'panel', carga_panel(p_sesion_id, 'panel'));
        END IF;
        v_ejec_id := carga_arrancar(p_sesion_id);
        IF v_ejec_id IS NULL THEN               -- otro llegó primero
            RETURN jsonb_build_object('accion', 'nada');
        END IF;
        RETURN jsonb_build_object('accion', 'analizar', 'ejecucion_id', v_ejec_id,
                 'panel', carga_panel(p_sesion_id, 'analizando'));
    END IF;

    -- Silencio y nadie pidió nada: solo refresco el contador.
    IF v_ses.estado = 'recibiendo' THEN
        RETURN jsonb_build_object('accion', 'panel',
                 'panel', carga_panel(p_sesion_id, 'panel'));
    END IF;

    RETURN jsonb_build_object('accion', 'nada');
END;
$function$
