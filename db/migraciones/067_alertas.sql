-- 067_alertas.sql — Chasqui habla primero.
--
-- Hasta acá todo lo que hace el sistema empieza porque el dueño escribió algo.
-- Sube archivos, pide el análisis, pregunta. Si sube las ventas de la semana y
-- no toca "Analizar", nadie le dice que un producto se le está agotando — aunque
-- el dato ya esté cargado y la regla ya lo sepa.
--
-- LA REGLA QUE GOBIERNA ESTA MIGRACIÓN
--
-- **Un bot que avisa de más lo silencian, y silenciado no sirve para nada.**
-- Todo lo de acá está diseñado alrededor de eso, no alrededor de avisar:
--
--   * Solo prioridad **alta**. Lo demás espera al informe.
--   * **Un** aviso por negocio por corrida. Nunca una ráfaga.
--   * **Cooldown** por regla+objeto: el mismo problema no se avisa dos veces en
--     dos semanas, aunque siga estando.
--   * **Horario**: nada fuera de la franja del negocio. Un aviso a las 3 de la
--     mañana es la forma más rápida de que lo bloqueen.
--   * Solo si **entraron datos nuevos** desde el último análisis. Sin datos
--     nuevos no hay nada que el dueño no haya visto ya.
--
-- LO QUE EL AVISO HACE, Y LO QUE NO
--
-- Avisa y ofrece el análisis. **No** registra la recomendación ni la marca como
-- vista: eso lo hace `recomendaciones_registrar` cuando hay un informe de
-- verdad (B2), y meter mano acá haría que `veces_vista` contara mensajes que no
-- son informes. El aviso lleva un hallazgo real —calculado con la misma función
-- que el informe— y un botón para ver todo.
--
-- CERO NODOS NUEVOS. `wf_cron` ya corre cada 5 minutos y ya hace fanout a
-- `wf_enviar`; `mantenimiento_ciclo` concatena estas notificaciones a las suyas.
-- El contrato de salida es el mismo desde la 016: `{chat_id, respuestas[]}`.

-- =============================================================================
-- 1. La memoria de lo avisado
-- =============================================================================
-- Sin esta tabla no hay cooldown, y sin cooldown Chasqui repite el mismo aviso
-- cada cinco minutos. Es la pieza que hace que la proactividad sea usable.
CREATE TABLE IF NOT EXISTS alertas_enviadas (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    negocio_id   bigint NOT NULL REFERENCES negocios(id),
    regla        text   NOT NULL,
    clave_objeto text   NOT NULL,
    prioridad    text,
    titulo       text,
    enviada_en   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE alertas_enviadas IS
  'Qué se avisó y cuándo. Es el cooldown: sin ella, el mismo problema se '
  'avisaría en cada corrida del cron.';

CREATE INDEX IF NOT EXISTS idx_alertas_cooldown
    ON alertas_enviadas (negocio_id, regla, clave_objeto, enviada_en DESC);

-- =============================================================================
-- 2. Los umbrales de la proactividad
-- =============================================================================
INSERT INTO parametros (negocio_id, clave, valor) VALUES
  -- Días antes de poder repetir el MISMO aviso. Dos semanas: si el problema
  -- sigue después de eso, insistir una vez es razonable; antes, es acoso.
  (NULL, 'alerta_cooldown_dias',  '14'::jsonb),
  -- Franja horaria del negocio. Un aviso a las 3 AM es la forma más rápida de
  -- que lo bloqueen.
  (NULL, 'alerta_hora_desde',     '8'::jsonb),
  (NULL, 'alerta_hora_hasta',     '20'::jsonb),
  -- Avisos por negocio y por corrida. Uno. Si hay tres cosas urgentes, la más
  -- urgente primero y el resto en el informe.
  (NULL, 'alerta_max_por_corrida', '1'::jsonb),
  (NULL, 'zona_horaria', '"America/Bogota"'::jsonb)
ON CONFLICT (clave) WHERE negocio_id IS NULL
DO UPDATE SET valor = EXCLUDED.valor;

-- =============================================================================
-- 3. Quién está en condiciones de recibir un aviso
-- =============================================================================
-- Cuatro condiciones, y las cuatro son para NO avisar:
--   * hay a quién avisarle, y autorizó el tratamiento de sus datos (051);
--   * entraron movimientos DESPUÉS del último análisis — si no, lo que haya que
--     decir ya se lo dijo el informe;
--   * es horario del negocio;
--   * y hay algo de prioridad alta que no se le avisó hace poco.
CREATE OR REPLACE VIEW v_negocios_alertables AS
SELECT n.id AS negocio_id,
       u.id AS usuario_id,
       u.telegram_chat_id AS chat_id,
       m.ultimo_dato,
       e.ultimo_analisis
FROM negocios n
JOIN LATERAL (
    SELECT id, telegram_chat_id FROM usuarios
    WHERE negocio_id = n.id AND autorizacion_datos
      AND telegram_chat_id IS NOT NULL
    ORDER BY id LIMIT 1) u ON true
CROSS JOIN LATERAL (
    SELECT max(creado_en) AS ultimo_dato FROM mov_visibles
    WHERE negocio_id = n.id) m
CROSS JOIN LATERAL (
    SELECT max(fin) AS ultimo_analisis FROM ejecuciones
    WHERE negocio_id = n.id AND estado = 'completada'
      AND servicio_codigo IN (SELECT codigo FROM servicios WHERE entrada = 'archivos')) e
WHERE m.ultimo_dato IS NOT NULL
  -- Datos nuevos desde el último análisis. Un negocio que nunca analizó pero ya
  -- cargó datos también entra: es el caso en que más falta hace el empujón.
  AND (e.ultimo_analisis IS NULL OR m.ultimo_dato > e.ultimo_analisis);

-- =============================================================================
-- 4. El motor
-- =============================================================================
CREATE OR REPLACE FUNCTION alertas_evaluar()
RETURNS jsonb LANGUAGE plpgsql AS $$
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
$$;

INSERT INTO plantillas (clave, cuerpo, formato, teclado) VALUES
('alerta.hallazgo',
'🔔 <b>Miré lo último que cargaste</b>

{{icono}} <b>{{titulo}}</b>
{{problema}}

{{impacto}}',
 'html',
 jsonb_build_array(
   jsonb_build_array(jsonb_build_object('texto', '📊 Ver el análisis completo',
                                        'dato', '/nueva')),
   jsonb_build_array(jsonb_build_object('texto', '✅ Ya hice algo',
                                        'dato', 'rec:list'))))
ON CONFLICT (clave) DO UPDATE
  SET cuerpo = EXCLUDED.cuerpo, formato = EXCLUDED.formato,
      teclado = EXCLUDED.teclado, activo = true;

-- =============================================================================
-- 5. Entra al ciclo que ya corre
-- =============================================================================
-- Cero nodos nuevos: `mantenimiento_ciclo` concatena las notificaciones de las
-- alertas a las suyas, y `wf_cron` las despacha con el fanout que ya tiene.
-- El contrato de salida no cambia desde la 016.
CREATE OR REPLACE FUNCTION mantenimiento_ciclo()
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_notif jsonb := '[]';
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

    -- 3. >>> 067: proactividad. Va con su propio guardarraíl: si evaluar las
    -- reglas de un negocio revienta, el reaper —que es lo que no puede dejar de
    -- correr— ya hizo su trabajo y las notificaciones salen igual.
    BEGIN
        v_notif := v_notif || coalesce(alertas_evaluar() -> 'notificaciones',
                                       '[]'::jsonb);
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO fallas (workflow, tipo, transitoria, detalle)
        VALUES ('alertas_evaluar', 'permanente', false,
                jsonb_build_object('mensaje', SQLERRM, 'sqlstate', SQLSTATE));
    END;

    RETURN jsonb_build_object('corrido_en', now(), 'notificaciones', v_notif);
END;
$$;

NOTIFY pgrst, 'reload schema';
