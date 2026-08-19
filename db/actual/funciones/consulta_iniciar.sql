CREATE OR REPLACE FUNCTION public.consulta_iniciar(p_usuario_id bigint, p_negocio_id bigint, p_chat_id bigint, p_pregunta text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_hechos   jsonb;
    v_hay_kb   boolean;
    v_hay_num  boolean;
    v_sesion   bigint;
    v_ejec     bigint;
BEGIN
    v_hechos := conocimiento_buscar(p_negocio_id, p_pregunta);
    v_hay_kb := v_hechos IS NOT NULL AND jsonb_array_length(v_hechos) > 0;

    -- `mov_visibles` y no `movimientos`: la compuerta tiene que coincidir con
    -- lo que el análisis va a poder usar de verdad (C9/053).
    SELECT EXISTS (SELECT 1 FROM mov_visibles WHERE negocio_id = p_negocio_id)
      INTO v_hay_num;

    IF NOT v_hay_kb AND NOT v_hay_num THEN
        -- Sin KB y sin números no hay nada que responder. La pregunta se
        -- registra: es señal de qué le falta a la base de conocimiento.
        PERFORM conocimiento_pendiente_registrar(p_negocio_id, p_pregunta);
        RETURN router_respuesta(p_chat_id, 'consulta.sin_datos');
    END IF;

    -- Si hay números pero la KB no tenía nada, la pregunta igual se anota: que
    -- se pueda responder con agregados no quita que un dato cargado a mano la
    -- respondería mejor.
    IF NOT v_hay_kb THEN
        PERFORM conocimiento_pendiente_registrar(p_negocio_id, p_pregunta);
    END IF;

    -- La sesión nace y muere en esta ejecución: no hay turnos que mantener.
    -- ejecucion_cerrar la cierra igual que la de un informe.
    INSERT INTO sesiones (usuario_id, negocio_id, servicio_codigo, estado, paso, contexto)
    VALUES (p_usuario_id, p_negocio_id, 'consulta', 'procesando', 'ejecutando',
            jsonb_build_object('pregunta', p_pregunta))
    RETURNING id INTO v_sesion;

    INSERT INTO ejecuciones (sesion_id, negocio_id, servicio_codigo, estado)
    VALUES (v_sesion, p_negocio_id, 'consulta', 'preparando')
    RETURNING id INTO v_ejec;

    RETURN router_respuesta(p_chat_id, 'consulta.pensando', '{}'::jsonb, NULL,
             jsonb_build_array(jsonb_build_object('tipo','ejecutar','ejecucion_id', v_ejec)));
END;
$function$
