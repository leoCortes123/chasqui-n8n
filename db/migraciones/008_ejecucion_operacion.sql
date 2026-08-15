-- 008_ejecucion_operacion.sql — el motor genérico de ejecución, la validación
-- de cifras, el reaper y la observabilidad. Todo SQL: n8n solo orquesta HTTP.

-- === Consumo por negocio (control de costo) ================================
CREATE VIEW v_consumo_negocio AS
SELECT n.id AS negocio_id, n.nombre, n.cupo_tokens_mes,
       coalesce(sum(e.tokens_prompt + e.tokens_salida)
                FILTER (WHERE e.inicio >= date_trunc('month', now())), 0) AS tokens_mes,
       coalesce(sum(e.costo)
                FILTER (WHERE e.inicio >= date_trunc('month', now())), 0) AS costo_mes,
       count(e.id) FILTER (WHERE e.inicio >= date_trunc('month', now())
                             AND e.estado = 'completada')                 AS ejecuciones_mes
FROM negocios n
LEFT JOIN ejecuciones e ON e.negocio_id = n.id
GROUP BY n.id, n.nombre, n.cupo_tokens_mes;

-- === ejecucion_preparar: hallazgos + prompt + plantilla en una llamada =====
-- Es lo que mantiene wf_ejecutar genérico. Verifica el cupo ANTES de devolver
-- el prompt: si el negocio se pasó, devuelve {bloqueado:true} y no gasta tokens.
CREATE FUNCTION ejecucion_preparar(p_ejecucion_id bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_negocio_id bigint;
    v_servicio   text;
    v_cupo       bigint;
    v_usados     bigint;
    v_hallazgos  jsonb;
    v_prompt     record;
    v_pdf        record;
BEGIN
    SELECT negocio_id, servicio_codigo INTO v_negocio_id, v_servicio
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

    v_hallazgos := hallazgos_generar(v_negocio_id);

    SELECT id, sistema, usuario, modelo, temperatura, max_tokens
      INTO v_prompt
    FROM prompts WHERE servicio_codigo = v_servicio AND activo LIMIT 1;

    IF v_prompt.id IS NULL THEN
        UPDATE ejecuciones SET estado = 'fallida',
               error = format('sin prompt activo para %s', v_servicio), fin = now()
        WHERE id = p_ejecucion_id;
        RETURN jsonb_build_object('bloqueado', false, 'error', 'sin_prompt');
    END IF;

    SELECT id, html, css INTO v_pdf
    FROM plantillas_pdf WHERE servicio_codigo = v_servicio AND activo LIMIT 1;

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
            'max_tokens', v_prompt.max_tokens),
        'plantilla_pdf', CASE WHEN v_pdf.id IS NOT NULL
            THEN jsonb_build_object('id', v_pdf.id, 'html', v_pdf.html, 'css', v_pdf.css)
            ELSE NULL END
    );
END;
$$;

-- === ejecucion_cerrar: registra resultado y libera la sesión ===============
CREATE FUNCTION ejecucion_cerrar(p_ejecucion_id bigint, p_estado text, p_resultado jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_sesion_id bigint;
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
    RETURNING sesion_id INTO v_sesion_id;

    -- Cierra la sesión asociada según el desenlace.
    IF v_sesion_id IS NOT NULL THEN
        UPDATE sesiones SET
            estado     = CASE WHEN p_estado = 'completada' THEN 'completada'::estado_sesion
                              ELSE 'fallida'::estado_sesion END,
            cerrada_en = now()
        WHERE id = v_sesion_id;
    END IF;

    RETURN jsonb_build_object('ejecucion_id', p_ejecucion_id, 'estado', p_estado);
END;
$$;

-- === validar_cifras: el LLM redacta, no calcula ============================
-- Extrae con regex todos los números del texto y verifica que cada uno exista
-- en el JSON de hallazgos. Un número inventado invalida la narración: mejor un
-- informe seco que uno con cifras falsas.
CREATE FUNCTION validar_cifras(p_texto text, p_hallazgos jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_permitidos text[];
    v_num        text;
    v_inventadas text[] := '{}';
BEGIN
    -- Todos los números que aparecen en los hallazgos, normalizados sin
    -- separadores de miles ni ceros decimales colgantes.
    SELECT array_agg(DISTINCT n) INTO v_permitidos
    FROM (
        SELECT regexp_replace((regexp_matches(p_hallazgos::text, '\d+(?:\.\d+)?', 'g'))[1],
                              '\.0+$', '') AS n
    ) s;

    -- Cada número del texto debe estar permitido. Se recorta la puntuación
    -- final (punto de la frase), se quitan separadores de miles y ceros
    -- decimales colgantes para comparar contra los hallazgos.
    FOR v_num IN
        SELECT regexp_replace(
                 regexp_replace(
                   regexp_replace(rtrim(m[1], '.,'), '[.,](?=\d{3}\b)', '', 'g'),
                   '\.0+$', ''),
                 '\.$', '')
        FROM regexp_matches(p_texto, '\d[\d.,]*', 'g') AS m
    LOOP
        -- se ignoran números de 1-2 dígitos (porcentajes redondeados, conteos)
        IF length(regexp_replace(v_num, '\D', '', 'g')) >= 3
           AND NOT (v_num = ANY(v_permitidos)) THEN
            v_inventadas := array_append(v_inventadas, v_num);
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'ok', cardinality(v_inventadas) = 0,
        'inventadas', to_jsonb(v_inventadas)
    );
END;
$$;

-- === mantenimiento_ciclo: el reaper (corre cada 5 min por wf_cron) =========
-- Sin esto, una ejecución colgada deja al usuario esperando un informe que no
-- llega y nadie se entera. Devuelve a quién avisar.
CREATE FUNCTION mantenimiento_ciclo()
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_colgadas   jsonb;
    v_expiradas  jsonb;
BEGIN
    -- 1. Ejecuciones colgadas > 15 min en estado no terminal -> fallidas.
    WITH reaped AS (
        UPDATE ejecuciones e SET estado = 'fallida',
               error = 'reaper: colgada más de 15 min', fin = now()
        WHERE e.estado IN ('preparando','procesando','validando')
          AND e.inicio < now() - interval '15 minutes'
        RETURNING e.id, e.sesion_id, e.negocio_id
    ),
    libera AS (
        UPDATE sesiones s SET estado = 'fallida', cerrada_en = now()
        FROM reaped r WHERE s.id = r.sesion_id
        RETURNING s.id
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'ejecucion_id', id, 'sesion_id', sesion_id, 'negocio_id', negocio_id)), '[]')
      INTO v_colgadas FROM reaped;

    -- 2. Sesiones abandonadas > 24 h -> expiradas (un recordatorio y a cerrar).
    WITH exp AS (
        UPDATE sesiones s SET estado = 'expirada', cerrada_en = now()
        WHERE s.cerrada_en IS NULL
          AND s.estado IN ('intake','recibiendo')
          AND s.ultima_actividad < now() - interval '24 hours'
        RETURNING s.id, s.usuario_id
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'sesion_id', id, 'usuario_id', usuario_id)), '[]')
      INTO v_expiradas FROM exp;

    RETURN jsonb_build_object(
        'corrido_en', now(),
        'ejecuciones_reaped', v_colgadas,
        'sesiones_expiradas', v_expiradas
    );
END;
$$;

-- === Vistas de operación (observabilidad = SELECTs) ========================
CREATE VIEW v_sesiones_atascadas AS
SELECT s.id AS sesion_id, s.negocio_id, s.servicio_codigo, s.paso, s.estado,
       s.ultima_actividad, now() - s.ultima_actividad AS antiguedad
FROM sesiones s
WHERE s.cerrada_en IS NULL
ORDER BY s.ultima_actividad;

CREATE VIEW v_embudo_servicios AS
SELECT servicio_codigo,
       count(*)                                              AS iniciadas,
       count(*) FILTER (WHERE estado = 'completada')         AS completadas,
       count(*) FILTER (WHERE estado = 'expirada')           AS abandonadas,
       count(*) FILTER (WHERE estado = 'fallida')            AS fallidas,
       mode() WITHIN GROUP (ORDER BY paso)
         FILTER (WHERE estado IN ('expirada','fallida'))     AS paso_de_caida
FROM sesiones
GROUP BY servicio_codigo;

CREATE VIEW v_ejecuciones_fallidas AS
SELECT e.id AS ejecucion_id, e.negocio_id, e.servicio_codigo, e.error, e.inicio, e.fin
FROM ejecuciones e
WHERE e.estado = 'fallida' AND e.inicio >= now() - interval '24 hours'
ORDER BY e.inicio DESC;

CREATE VIEW v_calidad_matching AS
SELECT negocio_id,
       count(*)                                          AS aliases,
       count(*) FILTER (WHERE producto_id IS NOT NULL)   AS resueltos,
       count(*) FILTER (WHERE producto_id IS NULL)       AS pendientes,
       count(*) FILTER (WHERE origen = 'trigram')        AS por_trigram,
       count(*) FILTER (WHERE origen = 'manual')         AS confirmados_manual,
       round(100.0 * count(*) FILTER (WHERE producto_id IS NOT NULL)
             / nullif(count(*), 0), 1)                   AS pct_resuelto
FROM alias
GROUP BY negocio_id;

CREATE VIEW v_salud_ingesta AS
WITH por_estado AS (
    SELECT negocio_id, formato_codigo, estado, count(*) AS documentos
    FROM documentos
    GROUP BY negocio_id, formato_codigo, estado
)
SELECT negocio_id, formato_codigo, estado, documentos,
       round(100.0 * sum(documentos) FILTER (WHERE estado = 'error')
                       OVER (PARTITION BY negocio_id, formato_codigo)
             / nullif(sum(documentos) OVER (PARTITION BY negocio_id, formato_codigo), 0), 1)
                                                    AS pct_error_formato
FROM por_estado
ORDER BY negocio_id, formato_codigo, estado;
