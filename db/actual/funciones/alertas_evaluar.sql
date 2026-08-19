CREATE OR REPLACE FUNCTION public.alertas_evaluar()
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_cool  int  := coalesce((parametro(NULL,'alerta_cooldown_dias'))::text::int, 14);
    v_desde int  := coalesce((parametro(NULL,'alerta_hora_desde'))::text::int, 8);
    v_hasta int  := coalesce((parametro(NULL,'alerta_hora_hasta'))::text::int, 20);
    v_max   int  := coalesce((parametro(NULL,'alerta_max_por_corrida'))::text::int, 1);
    v_tz    text := coalesce(btrim((parametro(NULL,'zona_horaria'))::text, '"'),
                             'America/Bogota');
    v_hora  int;
    v_notif jsonb := '[]'::jsonb;
    n       record;
    a       record;
BEGIN
    v_hora := extract(hour FROM (now() AT TIME ZONE v_tz))::int;
    IF v_hora < v_desde OR v_hora >= v_hasta THEN
        -- Fuera de horario no se evalúa siquiera: además de no molestar, se
        -- ahorra recorrer las reglas de todos los negocios de madrugada.
        RETURN jsonb_build_object('corrido_en', now(), 'fuera_de_horario', true,
                                  'notificaciones', '[]'::jsonb);
    END IF;

    FOR n IN SELECT * FROM v_negocios_alertables LOOP
        -- Se usa la MISMA función que el informe, en modo registro para ver
        -- todo lo detectado. Es una lectura pura: no escribe recomendaciones ni
        -- toca `veces_vista` — eso solo pasa cuando hay un informe de verdad.
        SELECT e.regla, e.clave_objeto, e.titulo, e.problema, e.impacto,
               e.impacto_mes, e.icono
          INTO a
        FROM jsonb_to_recordset(recomendaciones_negocio(n.negocio_id, true))
               AS e(regla text, clave_objeto text, titulo text, problema text,
                    impacto text, impacto_mes numeric, prioridad text, icono text)
        WHERE e.prioridad = 'alta'
          AND NOT EXISTS (
                SELECT 1 FROM alertas_enviadas al
                 WHERE al.negocio_id = n.negocio_id
                   AND al.regla = e.regla AND al.clave_objeto = e.clave_objeto
                   AND al.enviada_en > now() - make_interval(days => v_cool))
        ORDER BY e.impacto_mes DESC NULLS LAST
        LIMIT v_max;

        CONTINUE WHEN a.regla IS NULL;

        INSERT INTO alertas_enviadas (negocio_id, regla, clave_objeto, prioridad, titulo)
        VALUES (n.negocio_id, a.regla, a.clave_objeto, 'alta', a.titulo);

        v_notif := v_notif || jsonb_build_array(jsonb_build_object(
          'chat_id', n.chat_id,
          'respuestas', jsonb_build_array(jsonb_build_object(
            'plantilla', 'alerta.hallazgo',
            'vars', jsonb_build_object(
              'icono',    coalesce(a.icono, '🔔'),
              'titulo',   a.titulo,
              'problema', coalesce(a.problema, ''),
              'impacto',  coalesce(a.impacto, ''))))));
    END LOOP;

    RETURN jsonb_build_object('corrido_en', now(), 'notificaciones', v_notif);
END;
$function$
