-- 024_router_botones.sql — la conversación se maneja a botonazos.
--
-- Tres cambios de fondo:
--
-- 1. Un botón no abre un camino nuevo. n8n normaliza el `callback_data` al mismo
--    campo `texto` que trae un mensaje escrito, así que el router atiende los dos
--    con el mismo código. Los `dato` de los teclados son literalmente los
--    comandos (/nueva, /listo, /cancelar, acepto): quien quiera escribir, puede.
--    El único formato nuevo es `svc:<codigo>` para elegir servicio sin tipear.
--
-- 2. Se dejan de pedir pasos que el sistema puede resolver solo:
--      * Con un único servicio activo, /nueva ya no pregunta cuál: arranca.
--      * Un archivo suelto, sin sesión abierta, ABRE la sesión y se procesa.
--        Antes contestaba "no tenés un análisis en curso" y el usuario tenía que
--        empezar de cero y volver a mandar el archivo.
--
-- 3. Estados que antes caían en "no te entendí" ahora tienen respuesta propia:
--    tocar Analizar dos veces, o elegir servicio cuando ya hay uno elegido.
--    Esto además hace inofensivos los teclados viejos que quedan en el historial:
--    no hace falta borrarlos, un botón rancio contesta algo sensato.
--
-- router_respuesta arma el valor de retorno. Existe por dos razones: deja de
-- repetirse quince veces el mismo jsonb_build_object, y elimina de raíz el
-- error de la migración 016 (literales '{}' entrando como text en vez de jsonb).

CREATE FUNCTION router_respuesta(p_chat bigint,
                                 p_plantilla text,
                                 p_vars jsonb DEFAULT '{}'::jsonb,
                                 p_teclado jsonb DEFAULT NULL,
                                 p_acciones jsonb DEFAULT '[]'::jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object(
      'chat_id', p_chat,
      'respuestas', CASE WHEN p_plantilla IS NULL THEN '[]'::jsonb
                    ELSE jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                           'plantilla', p_plantilla,
                           'vars', coalesce(p_vars, '{}'::jsonb),
                           'teclado', p_teclado))) END,
      'acciones', coalesce(p_acciones, '[]'::jsonb));
$$;

CREATE OR REPLACE FUNCTION router_procesar_mensaje(p_evento jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_usuario_id bigint;
    v_chat_id    bigint  := (p_evento #>> '{chat,id}')::bigint;
    v_texto      text    := btrim(coalesce(p_evento ->> 'texto', ''));
    v_cmd        text;
    v_svc        text;          -- código que llegó por botón (svc:<codigo>)
    v_tiene_doc  boolean := coalesce((p_evento ->> 'tiene_documento')::boolean, false);
    v_sesion     record;
    v_negocio_id bigint;
    v_autoriz    boolean;
    v_rol        rol_usuario;
    v_servicio   record;
    v_n_serv     int;
    v_ejec_id    bigint;
    v_nueva_ses  bigint;
BEGIN
    v_cmd := lower(split_part(v_texto, ' ', 1));
    IF v_texto LIKE 'svc:%' THEN
        v_svc := substring(v_texto FROM 5);
        v_cmd := 'svc';
    END IF;

    v_usuario_id := usuario_de_telegram(p_evento);
    SELECT negocio_id, autorizacion_datos, rol
      INTO v_negocio_id, v_autoriz, v_rol
    FROM usuarios WHERE id = v_usuario_id;

    SELECT count(*) INTO v_n_serv FROM servicios WHERE activo;

    -- ---- Comandos de admin -------------------------------------------------
    IF v_cmd IN ('/salud','/embudo','/fallas','/consumo','/matching','/admin') THEN
        IF v_rol <> 'admin' THEN
            RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
        END IF;
        -- admin_reporte devuelve el texto ya armado; resolver_plantilla lo pasa
        -- tal cual (escapado) al no encontrar plantilla con esa clave.
        RETURN router_respuesta(v_chat_id, admin_reporte(v_cmd));
    END IF;

    SELECT * INTO v_sesion FROM sesiones
    WHERE usuario_id = v_usuario_id AND cerrada_en IS NULL
    ORDER BY id DESC LIMIT 1;
    IF v_sesion.id IS NOT NULL THEN
        UPDATE sesiones SET ultima_actividad = now() WHERE id = v_sesion.id;
    END IF;

    -- ---- Informativos: accesibles incluso sin autorizar --------------------
    IF v_cmd IN ('/start','/help','/ayuda') THEN
        RETURN router_respuesta(v_chat_id, 'sistema.bienvenida');
    END IF;
    IF v_cmd = '/comofunciona' THEN
        RETURN router_respuesta(v_chat_id, 'sistema.como_funciona');
    END IF;
    IF v_cmd = '/privacidad' THEN
        RETURN router_respuesta(v_chat_id, 'sistema.privacidad');
    END IF;

    -- ---- Autorización de datos (una sola vez) ------------------------------
    IF NOT v_autoriz THEN
        IF lower(v_texto) IN ('acepto','autorizo','si','sí','ok','dale') THEN
            UPDATE usuarios SET autorizacion_datos = true, autorizacion_fecha = now()
            WHERE id = v_usuario_id;
            RETURN router_respuesta(v_chat_id, 'sistema.bienvenida');
        END IF;
        RETURN router_respuesta(v_chat_id, 'sistema.no_autorizado');
    END IF;

    -- ---- Cancelar ----------------------------------------------------------
    IF v_cmd IN ('/cancelar','/cancel') THEN
        IF v_sesion.id IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.sin_sesion');
        END IF;
        UPDATE sesiones SET estado = 'expirada', cerrada_en = now()
        WHERE usuario_id = v_usuario_id AND cerrada_en IS NULL;
        RETURN router_respuesta(v_chat_id, 'sesion.cancelada');
    END IF;

    -- ---- /nueva ------------------------------------------------------------
    IF v_cmd = '/nueva' THEN
        UPDATE sesiones SET estado = 'expirada', cerrada_en = now()
        WHERE usuario_id = v_usuario_id AND cerrada_en IS NULL;

        -- Con un solo servicio activo, preguntar cuál es un paso vacío.
        IF v_n_serv = 1 THEN
            SELECT * INTO v_servicio FROM servicios WHERE activo LIMIT 1;
            INSERT INTO sesiones (usuario_id, negocio_id, servicio_codigo, estado, paso)
            VALUES (v_usuario_id, v_negocio_id, v_servicio.codigo, 'recibiendo', 'cargar_archivos');
            RETURN router_respuesta(v_chat_id, 'sistema.pedir_archivos',
                     jsonb_build_object('servicio', v_servicio.nombre));
        END IF;

        INSERT INTO sesiones (usuario_id, negocio_id, estado, paso)
        VALUES (v_usuario_id, v_negocio_id, 'intake', 'elegir_servicio');
        RETURN router_respuesta(v_chat_id, 'sistema.elegir_servicio',
                 '{}'::jsonb, teclado_servicios());
    END IF;

    -- ---- Sin sesión abierta ------------------------------------------------
    IF v_sesion.id IS NULL THEN
        -- Un archivo suelto es intención suficiente: se abre la sesión y se
        -- procesa, en vez de mandarlo a empezar de cero. Si hay más de un
        -- servicio no se puede adivinar, así que ahí sí se pregunta.
        IF v_tiene_doc AND v_n_serv = 1 THEN
            SELECT * INTO v_servicio FROM servicios WHERE activo LIMIT 1;
            INSERT INTO sesiones (usuario_id, negocio_id, servicio_codigo, estado, paso)
            VALUES (v_usuario_id, v_negocio_id, v_servicio.codigo, 'recibiendo', 'cargar_archivos')
            RETURNING id INTO v_nueva_ses;
            RETURN router_respuesta(v_chat_id, 'sistema.archivo_sin_sesion',
                     jsonb_build_object('servicio', v_servicio.nombre), NULL,
                     jsonb_build_array(jsonb_build_object(
                       'tipo','ingerir','sesion_id', v_nueva_ses)));
        END IF;
        IF v_tiene_doc THEN
            RETURN router_respuesta(v_chat_id, 'sistema.elegir_servicio',
                     '{}'::jsonb, teclado_servicios());
        END IF;
        RETURN router_respuesta(v_chat_id, 'sistema.sin_sesion');
    END IF;

    -- ---- Ya se está ejecutando: nada de disparar una segunda corrida -------
    IF v_sesion.estado = 'procesando' THEN
        RETURN router_respuesta(v_chat_id, 'ejecucion.ya_en_curso');
    END IF;

    -- ---- Intake: elegir servicio ------------------------------------------
    IF v_sesion.estado = 'intake' AND v_sesion.paso = 'elegir_servicio' THEN
        IF v_cmd = 'svc' THEN
            SELECT * INTO v_servicio FROM servicios WHERE activo AND codigo = v_svc;
        ELSIF v_tiene_doc AND v_n_serv = 1 THEN
            -- Mandó el archivo antes de elegir: se elige por él.
            SELECT * INTO v_servicio FROM servicios WHERE activo LIMIT 1;
        ELSE
            SELECT * INTO v_servicio FROM servicios
            WHERE activo AND (norm_texto(nombre) LIKE '%'||norm_texto(v_texto)||'%'
                              OR norm_texto(v_texto) LIKE '%'||norm_texto(nombre)||'%'
                              OR codigo = lower(v_texto))
            ORDER BY orden LIMIT 1;
        END IF;

        IF v_servicio.codigo IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.servicio_no_reconocido',
                     '{}'::jsonb, teclado_servicios());
        END IF;

        UPDATE sesiones SET servicio_codigo = v_servicio.codigo, estado = 'recibiendo',
               paso = 'cargar_archivos' WHERE id = v_sesion.id;

        IF v_tiene_doc THEN
            RETURN router_respuesta(v_chat_id, NULL, NULL, NULL,
                     jsonb_build_array(jsonb_build_object(
                       'tipo','ingerir','sesion_id', v_sesion.id)));
        END IF;
        RETURN router_respuesta(v_chat_id, 'sistema.pedir_archivos',
                 jsonb_build_object('servicio', v_servicio.nombre));
    END IF;

    -- ---- Recibiendo archivos ----------------------------------------------
    IF v_sesion.estado = 'recibiendo' THEN
        IF v_tiene_doc THEN
            -- La descarga y el parseo los hace wf_ingesta; el router delega.
            RETURN router_respuesta(v_chat_id, NULL, NULL, NULL,
                     jsonb_build_array(jsonb_build_object(
                       'tipo','ingerir','sesion_id', v_sesion.id)));
        END IF;

        -- Botón de servicio tocado de nuevo (teclado viejo del historial).
        IF v_cmd = 'svc' THEN
            RETURN router_respuesta(v_chat_id, 'sistema.servicio_ya_elegido',
                     jsonb_build_object('servicio',
                       (SELECT nombre FROM servicios WHERE codigo = v_sesion.servicio_codigo)));
        END IF;

        IF v_cmd IN ('/listo','/analizar','/fin') THEN
            IF NOT EXISTS (SELECT 1 FROM documentos
                           WHERE sesion_id = v_sesion.id AND estado = 'parseado') THEN
                RETURN router_respuesta(v_chat_id, 'sistema.sin_documentos');
            END IF;

            UPDATE sesiones SET estado = 'procesando', paso = 'ejecutando'
            WHERE id = v_sesion.id;
            INSERT INTO ejecuciones (sesion_id, negocio_id, servicio_codigo, estado)
            VALUES (v_sesion.id, v_negocio_id, v_sesion.servicio_codigo, 'preparando')
            RETURNING id INTO v_ejec_id;

            RETURN router_respuesta(v_chat_id, 'ejecucion.en_curso', '{}'::jsonb, NULL,
                     jsonb_build_array(jsonb_build_object(
                       'tipo','ejecutar','ejecucion_id', v_ejec_id)));
        END IF;

        RETURN router_respuesta(v_chat_id, 'sistema.esperando_listo');
    END IF;

    RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
END;
$$;
