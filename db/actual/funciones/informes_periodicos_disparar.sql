CREATE OR REPLACE FUNCTION public.informes_periodicos_disparar()
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_desde int  := coalesce((parametro(NULL,'alerta_hora_desde'))::text::int, 8);
    v_hasta int  := coalesce((parametro(NULL,'alerta_hora_hasta'))::text::int, 20);
    v_tz    text := coalesce(btrim((parametro(NULL,'zona_horaria'))::text, '"'),
                             'America/Bogota');
    v_srv   text;
    v_hora  int;
    v_notif jsonb := '[]'::jsonb;
    v_ejecs jsonb := '[]'::jsonb;
    v_ses   bigint;
    v_ejec  bigint;
    n       record;
BEGIN
    IF coalesce((parametro(NULL,'informe_periodico_activo'))::text::boolean, true) = false THEN
        RETURN jsonb_build_object('notificaciones', '[]'::jsonb,
                                  'ejecuciones', '[]'::jsonb, 'apagado', true);
    END IF;

    v_hora := extract(hour FROM (now() AT TIME ZONE v_tz))::int;
    IF v_hora < v_desde OR v_hora >= v_hasta THEN
        RETURN jsonb_build_object('notificaciones', '[]'::jsonb,
                                  'ejecuciones', '[]'::jsonb,
                                  'fuera_de_horario', true);
    END IF;

    SELECT codigo INTO v_srv FROM servicios
    WHERE activo AND entrada = 'archivos' ORDER BY orden LIMIT 1;
    IF v_srv IS NULL THEN
        RETURN jsonb_build_object('notificaciones', '[]'::jsonb,
                                  'ejecuciones', '[]'::jsonb);
    END IF;

    FOR n IN SELECT * FROM v_negocios_informe_periodico LOOP
        INSERT INTO sesiones (usuario_id, negocio_id, servicio_codigo, estado, paso, contexto)
        VALUES (n.usuario_id, n.negocio_id, v_srv, 'procesando', 'ejecutando',
                jsonb_build_object('origen', 'periodico'))
        RETURNING id INTO v_ses;

        INSERT INTO ejecuciones (sesion_id, negocio_id, servicio_codigo, estado)
        VALUES (v_ses, n.negocio_id, v_srv, 'preparando')
        RETURNING id INTO v_ejec;

        -- El aviso va ANTES. Un informe que aparece sin explicación se lee como
        -- spam por bueno que sea, y encima el dueño no sabe por qué le llegó.
        v_notif := v_notif || jsonb_build_array(jsonb_build_object(
          'chat_id', n.chat_id,
          'respuestas', jsonb_build_array(jsonb_build_object(
            'plantilla', 'informe.periodico_aviso',
            'vars', jsonb_build_object('movimientos', n.movs_nuevos)))));

        v_ejecs := v_ejecs || jsonb_build_array(
                     jsonb_build_object('tipo', 'ejecutar', 'ejecucion_id', v_ejec));
    END LOOP;

    RETURN jsonb_build_object('notificaciones', v_notif, 'ejecuciones', v_ejecs);
END;
$function$
