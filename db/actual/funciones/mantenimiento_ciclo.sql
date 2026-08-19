CREATE OR REPLACE FUNCTION public.mantenimiento_ciclo()
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_notif jsonb := '[]';
    v_ejecs jsonb := '[]'::jsonb;
    v_per   jsonb;
BEGIN
    -- 1. Ejecuciones colgadas > 15 min -> fallidas, libera sesión, avisa.
    WITH reaped AS (
        UPDATE ejecuciones e SET estado='fallida',
               error='reaper: colgada más de 15 min', fin=now()
        WHERE e.estado IN ('preparando','procesando','validando')
          AND e.inicio < now() - interval '15 minutes'
        RETURNING e.id, e.sesion_id, e.negocio_id
    ),
    libera AS (
        UPDATE sesiones s SET estado='fallida', cerrada_en=now()
        FROM reaped r WHERE s.id=r.sesion_id
        RETURNING s.id, s.usuario_id
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'chat_id', u.telegram_chat_id,
             'respuestas', jsonb_build_array(jsonb_build_object(
                 'plantilla','ejecucion.fallida','vars','{}'::jsonb)))), '[]')
      INTO v_notif
    FROM libera l JOIN usuarios u ON u.id = l.usuario_id
    WHERE u.telegram_chat_id IS NOT NULL;

    -- 2. Sesiones abandonadas > 24 h -> expiradas, recordatorio único.
    WITH exp AS (
        UPDATE sesiones s SET estado='expirada', cerrada_en=now()
        WHERE s.cerrada_en IS NULL
          AND s.estado IN ('intake','recibiendo')
          AND s.ultima_actividad < now() - interval '24 hours'
        RETURNING s.id, s.usuario_id
    )
    SELECT v_notif || coalesce(jsonb_agg(jsonb_build_object(
             'chat_id', u.telegram_chat_id,
             'respuestas', jsonb_build_array(jsonb_build_object(
                 'plantilla','sesion.recordatorio','vars','{}'::jsonb)))), '[]')
      INTO v_notif
    FROM exp e JOIN usuarios u ON u.id = e.usuario_id
    WHERE u.telegram_chat_id IS NOT NULL;

    -- 3. >>> 067: proactividad por hallazgo urgente.
    BEGIN
        v_notif := v_notif || coalesce(alertas_evaluar() -> 'notificaciones',
                                       '[]'::jsonb);
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO fallas (workflow, tipo, transitoria, detalle)
        VALUES ('alertas_evaluar', 'permanente', false,
                jsonb_build_object('mensaje', SQLERRM, 'sqlstate', SQLSTATE));
    END;

    -- 4. >>> 068: el informe periódico. Mismo guardarraíl: el reaper es lo que
    -- no puede dejar de correr, y ya corrió.
    BEGIN
        v_per   := informes_periodicos_disparar();
        v_notif := v_notif || coalesce(v_per -> 'notificaciones', '[]'::jsonb);
        v_ejecs := coalesce(v_per -> 'ejecuciones', '[]'::jsonb);
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO fallas (workflow, tipo, transitoria, detalle)
        VALUES ('informes_periodicos_disparar', 'permanente', false,
                jsonb_build_object('mensaje', SQLERRM, 'sqlstate', SQLSTATE));
    END;

    RETURN jsonb_build_object('corrido_en', now(),
                              'notificaciones', v_notif,
                              'ejecuciones', v_ejecs);
END;
$function$
