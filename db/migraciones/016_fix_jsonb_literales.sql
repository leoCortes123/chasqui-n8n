-- 016_fix_jsonb_literales.sql — corrige tipado de los literales JSON en el
-- router y el reaper.
--
-- El bug: jsonb_build_object('vars','{}') NO construye un objeto vacío, sino el
-- *string* JSON "{}"; igual con 'acciones','[]' -> "[]". Postgres solo infiere
-- jsonb cuando el literal se compara/asigna contra jsonb; como argumento
-- variádico de jsonb_build_object el literal entra como text.
--
--   jsonb_build_object('vars','{}')        -> {"vars": "{}"}   (mal)
--   jsonb_build_object('vars','{}'::jsonb) -> {"vars": {}}     (bien)
--
-- Consecuencias observadas:
--   * wf_enviar / nodo Resolver reventaba con "cannot call jsonb_each_text on a
--     non-object" al pasar '"{}"'::jsonb a resolver_plantilla. Ninguna plantilla
--     del sistema se podía resolver: el bot nunca respondía.
--   * wf_router / nodo Despachar recorría el string "[]" carácter por carácter
--     y metía ítems basura al Switch. Falla silenciosa, sin excepción.
--
-- Se arregla en dos capas: el origen (los literales, aquí abajo) y una red de
-- seguridad en resolver_plantilla para cualquier llamador futuro que se
-- equivoque igual.

-- === 1. Red de seguridad ====================================================
CREATE OR REPLACE FUNCTION resolver_plantilla(p_clave text, p_vars jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cuerpo  text;
    v_formato text;
    v_vars    jsonb;
    k text; val text;
BEGIN
    -- Tolera que lleguen vars mal tipadas (string, array, null): degrada a {}
    -- en vez de abortar la respuesta entera al usuario.
    v_vars := CASE WHEN jsonb_typeof(p_vars) = 'object' THEN p_vars ELSE '{}'::jsonb END;

    SELECT cuerpo, formato INTO v_cuerpo, v_formato
    FROM plantillas WHERE clave = p_clave AND activo LIMIT 1;

    IF v_cuerpo IS NULL THEN
        v_cuerpo := p_clave;  -- degradación: al menos manda la clave
        v_formato := 'markdown';
    END IF;

    FOR k, val IN SELECT * FROM jsonb_each_text(v_vars) LOOP
        v_cuerpo := replace(v_cuerpo, '{{' || k || '}}', coalesce(val, ''));
    END LOOP;

    RETURN jsonb_build_object('texto', v_cuerpo, 'formato', v_formato);
END;
$$;

-- === 2. router_procesar_mensaje (reemplaza la versión de 015) ===============
-- Idéntica a 015 salvo el ::jsonb en todos los literales.
CREATE OR REPLACE FUNCTION router_procesar_mensaje(p_evento jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_usuario_id bigint;
    v_chat_id    bigint := (p_evento #>> '{chat,id}')::bigint;
    v_texto      text   := btrim(coalesce(p_evento ->> 'texto', ''));
    v_cmd        text   := lower(split_part(v_texto, ' ', 1));
    v_tiene_doc  boolean := coalesce((p_evento ->> 'tiene_documento')::boolean, false);
    v_sesion     record;
    v_negocio_id bigint;
    v_autoriz    boolean;
    v_rol        rol_usuario;
    v_servicio   record;
    v_ejec_id    bigint;
BEGIN
    v_usuario_id := usuario_de_telegram(p_evento);
    SELECT negocio_id, autorizacion_datos, rol
      INTO v_negocio_id, v_autoriz, v_rol
    FROM usuarios WHERE id = v_usuario_id;

    -- ---- Comandos de admin (misma máquina de estados, restringido por rol) --
    IF v_cmd IN ('/salud','/embudo','/fallas','/consumo','/matching','/admin') THEN
        IF v_rol <> 'admin' THEN
            RETURN jsonb_build_object('chat_id', v_chat_id,
              'respuestas', jsonb_build_array(jsonb_build_object(
                'plantilla','sistema.no_entendido','vars','{}'::jsonb)),
              'acciones','[]'::jsonb);
        END IF;
        -- admin_reporte devuelve el texto ya armado; resolver_plantilla lo
        -- pasa tal cual al no encontrar plantilla con esa clave.
        RETURN jsonb_build_object('chat_id', v_chat_id,
          'respuestas', jsonb_build_array(jsonb_build_object(
            'plantilla', admin_reporte(v_cmd), 'vars', '{}'::jsonb)),
          'acciones','[]'::jsonb);
    END IF;

    SELECT * INTO v_sesion FROM sesiones
    WHERE usuario_id = v_usuario_id AND cerrada_en IS NULL
    ORDER BY id DESC LIMIT 1;
    IF FOUND THEN
        UPDATE sesiones SET ultima_actividad = now() WHERE id = v_sesion.id;
    END IF;

    IF v_cmd IN ('/start','/help','/ayuda') THEN
        RETURN jsonb_build_object('chat_id', v_chat_id,
            'respuestas', jsonb_build_array(jsonb_build_object(
              'plantilla','sistema.bienvenida','vars','{}'::jsonb)),
            'acciones','[]'::jsonb);
    END IF;

    IF NOT v_autoriz THEN
        IF lower(v_texto) IN ('acepto','autorizo','si','sí') THEN
            UPDATE usuarios SET autorizacion_datos=true, autorizacion_fecha=now() WHERE id=v_usuario_id;
            RETURN jsonb_build_object('chat_id', v_chat_id,
              'respuestas', jsonb_build_array(jsonb_build_object(
                'plantilla','sistema.bienvenida','vars','{}'::jsonb)),
              'acciones','[]'::jsonb);
        ELSE
            RETURN jsonb_build_object('chat_id', v_chat_id,
              'respuestas', jsonb_build_array(jsonb_build_object(
                'plantilla','sistema.no_autorizado','vars','{}'::jsonb)),
              'acciones','[]'::jsonb);
        END IF;
    END IF;

    IF v_cmd = '/nueva' THEN
        UPDATE sesiones SET estado='expirada', cerrada_en=now()
        WHERE usuario_id=v_usuario_id AND cerrada_en IS NULL;
        INSERT INTO sesiones (usuario_id, negocio_id, estado, paso)
        VALUES (v_usuario_id, v_negocio_id, 'intake', 'elegir_servicio');
        RETURN jsonb_build_object('chat_id', v_chat_id,
          'respuestas', jsonb_build_array(jsonb_build_object('plantilla','sistema.elegir_servicio',
            'vars', jsonb_build_object('lista',
              (SELECT string_agg('• ' || nombre, E'\n' ORDER BY orden) FROM servicios WHERE activo)))),
          'acciones','[]'::jsonb);
    END IF;

    IF v_sesion.id IS NULL THEN
        RETURN jsonb_build_object('chat_id', v_chat_id,
          'respuestas', jsonb_build_array(jsonb_build_object(
            'plantilla','sistema.sin_sesion','vars','{}'::jsonb)),
          'acciones','[]'::jsonb);
    END IF;

    IF v_sesion.estado='intake' AND v_sesion.paso='elegir_servicio' THEN
        SELECT * INTO v_servicio FROM servicios
        WHERE activo AND (norm_texto(nombre) LIKE '%'||norm_texto(v_texto)||'%'
                          OR norm_texto(v_texto) LIKE '%'||norm_texto(nombre)||'%'
                          OR codigo = lower(v_texto))
        ORDER BY orden LIMIT 1;
        IF v_servicio.codigo IS NULL THEN
            RETURN jsonb_build_object('chat_id', v_chat_id,
              'respuestas', jsonb_build_array(jsonb_build_object(
                'plantilla','sistema.servicio_no_reconocido','vars','{}'::jsonb)),
              'acciones','[]'::jsonb);
        END IF;
        UPDATE sesiones SET servicio_codigo=v_servicio.codigo, estado='recibiendo', paso='cargar_archivos' WHERE id=v_sesion.id;
        RETURN jsonb_build_object('chat_id', v_chat_id,
          'respuestas', jsonb_build_array(jsonb_build_object('plantilla','sistema.pedir_archivos',
            'vars', jsonb_build_object('servicio', v_servicio.nombre))),
          'acciones','[]'::jsonb);
    END IF;

    IF v_sesion.estado='recibiendo' THEN
        IF v_tiene_doc THEN
            RETURN jsonb_build_object('chat_id', v_chat_id, 'respuestas','[]'::jsonb,
              'acciones', jsonb_build_array(jsonb_build_object('tipo','ingerir','sesion_id',v_sesion.id)));
        END IF;
        IF v_cmd IN ('/listo','/analizar','/fin') THEN
            IF NOT EXISTS (SELECT 1 FROM documentos WHERE sesion_id=v_sesion.id AND estado='parseado') THEN
                RETURN jsonb_build_object('chat_id', v_chat_id,
                  'respuestas', jsonb_build_array(jsonb_build_object(
                    'plantilla','sistema.sin_documentos','vars','{}'::jsonb)),
                  'acciones','[]'::jsonb);
            END IF;
            UPDATE sesiones SET estado='procesando', paso='ejecutando' WHERE id=v_sesion.id;
            INSERT INTO ejecuciones (sesion_id, negocio_id, servicio_codigo, estado)
            VALUES (v_sesion.id, v_negocio_id, v_sesion.servicio_codigo, 'preparando')
            RETURNING id INTO v_ejec_id;
            RETURN jsonb_build_object('chat_id', v_chat_id,
              'respuestas', jsonb_build_array(jsonb_build_object(
                'plantilla','ejecucion.en_curso','vars','{}'::jsonb)),
              'acciones', jsonb_build_array(jsonb_build_object('tipo','ejecutar','ejecucion_id',v_ejec_id)));
        END IF;
        RETURN jsonb_build_object('chat_id', v_chat_id,
          'respuestas', jsonb_build_array(jsonb_build_object(
            'plantilla','sistema.esperando_listo','vars','{}'::jsonb)),
          'acciones','[]'::jsonb);
    END IF;

    RETURN jsonb_build_object('chat_id', v_chat_id,
      'respuestas', jsonb_build_array(jsonb_build_object(
        'plantilla','sistema.no_entendido','vars','{}'::jsonb)),
      'acciones','[]'::jsonb);
END;
$$;

-- === 3. mantenimiento_ciclo (reemplaza la versión de 014) ===================
-- Idéntica a 014 salvo el ::jsonb en 'vars'.
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

    RETURN jsonb_build_object('corrido_en', now(), 'notificaciones', v_notif);
END;
$$;
