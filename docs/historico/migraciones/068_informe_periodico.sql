-- 068_informe_periodico.sql — el informe que nadie pidió y todos necesitan.
--
-- E1 avisa cuando entran datos nuevos y hay algo urgente. Falta el otro lado de
-- la proactividad: el negocio que viene cargando datos todos los meses y nunca
-- vuelve a tocar "Analizar" porque ya vio uno y le pareció suficiente. Ese es el
-- que más se beneficia del comparativo — y es el que nunca lo va a pedir.
--
-- POR QUÉ RECIÉN AHORA
--
-- Un informe periódico antes de B1/B3 habría sido el mismo informe otra vez, con
-- las cifras del mes en curso y nada que decir sobre el anterior. Con la memoria
-- puesta, el informe automático **es** el comparativo: `hallazgos_comparativo`
-- (B3) ya viaja en los hallazgos, y las cuatro reglas comparativas ya disparan.
-- Es el momento en que "informe periódico" deja de ser una repetición y pasa a
-- ser información nueva.
--
-- LO QUE SE MANDA, Y CUÁNDO
--
--   * Un aviso corto primero: "pasó un mes, te preparo el resumen". Un informe
--     que aparece sin explicación se lee como spam, por bueno que sea.
--   * Después el informe de siempre, por el camino de siempre.
--
-- Las compuertas son las mismas de E1 y por la misma razón: horario del negocio,
-- y nada si ya hay un análisis en curso. Se suma una propia: **tiene que haber
-- datos nuevos desde el último informe**. Un negocio que no cargó nada en el mes
-- no necesita que le repitan lo que ya le dijeron.
--
-- UN NODO NUEVO EN `wf_cron`, Y ES INEVITABLE
--
-- E1 pudo hacerse con cero nodos porque una alerta es un mensaje, y `wf_cron` ya
-- sabía mandar mensajes. Un informe no es un mensaje: es una ejecución, y hay que
-- llamar a `wf_ejecutar`. El nodo se agrega al workflow que ya existe; no hay
-- workflow nuevo ni lógica nueva en n8n — el nodo solo despacha lo que Postgres
-- ya decidió.

-- =============================================================================
-- 1. Cada cuánto
-- =============================================================================
INSERT INTO parametros (negocio_id, clave, valor) VALUES
  -- Días desde el último análisis para preparar uno solo. 30 y no 7: el
  -- comparativo necesita que haya pasado algo entre medio, y un informe semanal
  -- sobre los mismos números es exactamente el ruido que E1 evita.
  (NULL, 'informe_periodico_dias', '30'::jsonb),
  -- Mínimo de movimientos nuevos para que valga la pena. Tres ventas sueltas no
  -- cambian ningún diagnóstico.
  (NULL, 'informe_periodico_min_movs', '10'::jsonb),
  (NULL, 'informe_periodico_activo', 'true'::jsonb)
ON CONFLICT (clave) WHERE negocio_id IS NULL
DO UPDATE SET valor = EXCLUDED.valor;

-- =============================================================================
-- 2. A quién le toca
-- =============================================================================
CREATE OR REPLACE VIEW v_negocios_informe_periodico AS
SELECT n.id AS negocio_id,
       u.id AS usuario_id,
       u.telegram_chat_id AS chat_id,
       e.ultimo_analisis,
       m.movs_nuevos
FROM negocios n
JOIN LATERAL (
    SELECT id, telegram_chat_id FROM usuarios
    WHERE negocio_id = n.id AND autorizacion_datos
      AND telegram_chat_id IS NOT NULL
    ORDER BY id LIMIT 1) u ON true
CROSS JOIN LATERAL (
    SELECT max(fin) AS ultimo_analisis FROM ejecuciones
    WHERE negocio_id = n.id AND estado = 'completada'
      AND servicio_codigo IN (SELECT codigo FROM servicios WHERE entrada = 'archivos')) e
CROSS JOIN LATERAL (
    SELECT count(*) AS movs_nuevos FROM mov_visibles
    WHERE negocio_id = n.id
      AND (e.ultimo_analisis IS NULL OR creado_en > e.ultimo_analisis)) m
WHERE
  -- Ya hubo al menos un informe: el primero lo pide el dueño, y así aprende qué
  -- es. Mandarle uno automático a alguien que nunca vio ninguno es empezar por
  -- el final.
  e.ultimo_analisis IS NOT NULL
  AND e.ultimo_analisis < now() - make_interval(days =>
        coalesce((parametro(NULL,'informe_periodico_dias'))::text::int, 30))
  AND m.movs_nuevos >= coalesce((parametro(NULL,'informe_periodico_min_movs'))::text::int, 10)
  -- Nada si ya hay algo corriendo: dos informes a la vez son un informe y una
  -- confusión.
  AND NOT EXISTS (
        SELECT 1 FROM ejecuciones x
         WHERE x.negocio_id = n.id
           AND x.estado IN ('preparando','procesando','validando'));

COMMENT ON VIEW v_negocios_informe_periodico IS
  'Negocios que ya vieron un informe, cargaron datos desde entonces y hace más '
  'de `informe_periodico_dias` que no analizan.';

-- =============================================================================
-- 3. El disparo
-- =============================================================================
-- Crea sesión y ejecución, igual que `consulta_iniciar`. La sesión hace falta:
-- `ejecucion_cerrar` saca de ahí a quién entregarle el informe, y sin ella el
-- informe se generaría para nadie.
CREATE OR REPLACE FUNCTION informes_periodicos_disparar()
RETURNS jsonb LANGUAGE plpgsql AS $$
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
$$;

INSERT INTO plantillas (clave, cuerpo, formato) VALUES
('informe.periodico_aviso',
'📅 <b>Pasó un mes desde tu último análisis</b>

Desde entonces cargaste {{movimientos}} movimientos nuevos, así que te preparo el resumen y te lo mando acá en un momento. Esta vez además lo comparo con cómo venías.

Si preferís que no te los mande solo, decímelo y lo apago.',
 'html')
ON CONFLICT (clave) DO UPDATE
  SET cuerpo = EXCLUDED.cuerpo, formato = EXCLUDED.formato, activo = true;

-- =============================================================================
-- 4. Entra al ciclo
-- =============================================================================
-- `mantenimiento_ciclo` gana una clave `ejecuciones` además de las
-- `notificaciones` que ya devolvía. El contrato viejo no cambia: quien solo lea
-- `notificaciones` sigue funcionando igual.
CREATE OR REPLACE FUNCTION mantenimiento_ciclo()
RETURNS jsonb LANGUAGE plpgsql AS $$
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
$$;

NOTIFY pgrst, 'reload schema';
