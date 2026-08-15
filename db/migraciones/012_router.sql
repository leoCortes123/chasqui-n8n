-- 012_router.sql — el cerebro de la conversación y el resolvedor de plantillas.
-- n8n normaliza el update de Telegram y llama a router_procesar_mensaje; recibe
-- respuestas[] (qué mandar) y acciones[] (qué disparar). Toda la máquina de
-- estados vive aquí, no en nodos.

-- Resuelve una plantilla con sus variables -> texto listo para enviar.
CREATE FUNCTION resolver_plantilla(p_clave text, p_vars jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cuerpo  text;
    v_formato text;
    k text; val text;
BEGIN
    SELECT cuerpo, formato INTO v_cuerpo, v_formato
    FROM plantillas WHERE clave = p_clave AND activo LIMIT 1;

    IF v_cuerpo IS NULL THEN
        v_cuerpo := p_clave;  -- degradación: al menos manda la clave
        v_formato := 'markdown';
    END IF;

    FOR k, val IN SELECT * FROM jsonb_each_text(coalesce(p_vars, '{}')) LOOP
        v_cuerpo := replace(v_cuerpo, '{{' || k || '}}', coalesce(val, ''));
    END LOOP;

    RETURN jsonb_build_object('texto', v_cuerpo, 'formato', v_formato);
END;
$$;

-- Localiza o crea el usuario por su id de Telegram.
CREATE FUNCTION usuario_de_telegram(p_evento jsonb)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_tid  bigint := (p_evento #>> '{from,id}')::bigint;
    v_chat bigint := (p_evento #>> '{chat,id}')::bigint;
    v_user text   := p_evento #>> '{from,username}';
    v_id   bigint;
BEGIN
    INSERT INTO usuarios (telegram_user_id, telegram_chat_id, telegram_username)
    VALUES (v_tid, v_chat, v_user)
    ON CONFLICT (telegram_user_id)
      DO UPDATE SET telegram_chat_id = EXCLUDED.telegram_chat_id,
                    telegram_username = coalesce(EXCLUDED.telegram_username, usuarios.telegram_username)
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$;

-- === router_procesar_mensaje ===============================================
-- p_evento: update normalizado {from:{id,username}, chat:{id}, texto, tiene_documento}
CREATE FUNCTION router_procesar_mensaje(p_evento jsonb)
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
    v_resp       jsonb := '[]';
    v_acc        jsonb := '[]';
BEGIN
    v_usuario_id := usuario_de_telegram(p_evento);
    SELECT negocio_id, autorizacion_datos, rol
      INTO v_negocio_id, v_autoriz, v_rol
    FROM usuarios WHERE id = v_usuario_id;

    -- sesión abierta más reciente
    SELECT * INTO v_sesion FROM sesiones
    WHERE usuario_id = v_usuario_id AND cerrada_en IS NULL
    ORDER BY id DESC LIMIT 1;

    IF FOUND THEN
        UPDATE sesiones SET ultima_actividad = now() WHERE id = v_sesion.id;
    END IF;

    -- ---- Comandos globales -------------------------------------------------
    IF v_cmd IN ('/start','/help','/ayuda') THEN
        RETURN jsonb_build_object('chat_id', v_chat_id,
            'respuestas', jsonb_build_array(jsonb_build_object('plantilla','sistema.bienvenida','vars','{}')),
            'acciones','[]');
    END IF;

    -- Autorización de datos (una vez).
    IF NOT v_autoriz THEN
        IF lower(v_texto) IN ('acepto','autorizo','si','sí') THEN
            UPDATE usuarios SET autorizacion_datos = true, autorizacion_fecha = now()
            WHERE id = v_usuario_id;
            v_resp := jsonb_build_array(jsonb_build_object('plantilla','sistema.bienvenida','vars','{}'));
            RETURN jsonb_build_object('chat_id', v_chat_id, 'respuestas', v_resp, 'acciones','[]');
        ELSE
            RETURN jsonb_build_object('chat_id', v_chat_id,
              'respuestas', jsonb_build_array(jsonb_build_object('plantilla','sistema.no_autorizado','vars','{}')),
              'acciones','[]');
        END IF;
    END IF;

    -- ---- /nueva: abre sesión de intake ------------------------------------
    IF v_cmd = '/nueva' THEN
        -- cierra cualquier sesión previa colgada del usuario
        UPDATE sesiones SET estado='expirada', cerrada_en=now()
        WHERE usuario_id=v_usuario_id AND cerrada_en IS NULL;

        INSERT INTO sesiones (usuario_id, negocio_id, estado, paso)
        VALUES (v_usuario_id, v_negocio_id, 'intake', 'elegir_servicio');

        RETURN jsonb_build_object('chat_id', v_chat_id,
          'respuestas', jsonb_build_array(jsonb_build_object('plantilla','sistema.elegir_servicio',
            'vars', jsonb_build_object('lista',
              (SELECT string_agg('• ' || nombre, E'\n' ORDER BY orden)
               FROM servicios WHERE activo)))),
          'acciones','[]');
    END IF;

    -- ---- Sin sesión abierta: guía ----------------------------------------
    IF NOT FOUND OR v_sesion.id IS NULL THEN
        RETURN jsonb_build_object('chat_id', v_chat_id,
          'respuestas', jsonb_build_array(jsonb_build_object('plantilla','sistema.sin_sesion','vars','{}')),
          'acciones','[]');
    END IF;

    -- ---- Intake: elegir servicio por texto --------------------------------
    IF v_sesion.estado = 'intake' AND v_sesion.paso = 'elegir_servicio' THEN
        SELECT * INTO v_servicio FROM servicios
        WHERE activo AND (norm_texto(nombre) LIKE '%'||norm_texto(v_texto)||'%'
                          OR norm_texto(v_texto) LIKE '%'||norm_texto(nombre)||'%'
                          OR codigo = lower(v_texto))
        ORDER BY orden LIMIT 1;

        IF v_servicio.codigo IS NULL THEN
            RETURN jsonb_build_object('chat_id', v_chat_id,
              'respuestas', jsonb_build_array(jsonb_build_object('plantilla','sistema.servicio_no_reconocido','vars','{}')),
              'acciones','[]');
        END IF;

        UPDATE sesiones SET servicio_codigo=v_servicio.codigo, estado='recibiendo',
               paso='cargar_archivos' WHERE id=v_sesion.id;

        RETURN jsonb_build_object('chat_id', v_chat_id,
          'respuestas', jsonb_build_array(jsonb_build_object('plantilla','sistema.pedir_archivos',
            'vars', jsonb_build_object('servicio', v_servicio.nombre))),
          'acciones','[]');
    END IF;

    -- ---- Recibiendo archivos ----------------------------------------------
    IF v_sesion.estado = 'recibiendo' THEN
        IF v_tiene_doc THEN
            -- La descarga/parseo la hace wf_ingesta; el router solo delega.
            RETURN jsonb_build_object('chat_id', v_chat_id, 'respuestas','[]',
              'acciones', jsonb_build_array(jsonb_build_object('tipo','ingerir','sesion_id',v_sesion.id)));
        END IF;

        IF v_cmd IN ('/listo','/analizar','/fin') THEN
            -- ¿hay documentos parseados?
            IF NOT EXISTS (SELECT 1 FROM documentos
                           WHERE sesion_id=v_sesion.id AND estado='parseado') THEN
                RETURN jsonb_build_object('chat_id', v_chat_id,
                  'respuestas', jsonb_build_array(jsonb_build_object('plantilla','sistema.sin_documentos','vars','{}')),
                  'acciones','[]');
            END IF;

            UPDATE sesiones SET estado='procesando', paso='ejecutando' WHERE id=v_sesion.id;
            INSERT INTO ejecuciones (sesion_id, negocio_id, servicio_codigo, estado)
            VALUES (v_sesion.id, v_negocio_id, v_sesion.servicio_codigo, 'preparando')
            RETURNING id INTO v_ejec_id;

            RETURN jsonb_build_object('chat_id', v_chat_id,
              'respuestas', jsonb_build_array(jsonb_build_object('plantilla','ejecucion.en_curso','vars','{}')),
              'acciones', jsonb_build_array(jsonb_build_object('tipo','ejecutar','ejecucion_id',v_ejec_id)));
        END IF;

        -- texto suelto mientras recibe
        RETURN jsonb_build_object('chat_id', v_chat_id,
          'respuestas', jsonb_build_array(jsonb_build_object('plantilla','sistema.esperando_listo','vars','{}')),
          'acciones','[]');
    END IF;

    -- ---- Fallback ----------------------------------------------------------
    RETURN jsonb_build_object('chat_id', v_chat_id,
      'respuestas', jsonb_build_array(jsonb_build_object('plantilla','sistema.no_entendido','vars','{}')),
      'acciones','[]');
END;
$$;
