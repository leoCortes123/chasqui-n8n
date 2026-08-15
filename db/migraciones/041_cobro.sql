-- 041_cobro.sql — Fase 3 sin WhatsApp: el cobro, a mano y sin vergüenza.
--
-- No hay pasarela integrada ni suscripciones (sección 7 del plan: eso no se
-- toca antes del primer cliente que paga). El circuito es:
--
--   1. El operador crea el enlace de pago en Wompi (a mano, en su panel) y lo
--      guarda como parámetro del negocio:
--        INSERT INTO parametros (negocio_id, clave, valor)
--        VALUES (1, 'pago_enlace', '"https://checkout.wompi.co/l/XXXX"');
--      (o UPDATE si ya existe; el valor es un string jsonb, con comillas)
--   2. El dueño escribe /plan y ve su plan, el consumo del mes y el enlace.
--   3. Pagado el enlace, el operador actualiza a mano:
--        UPDATE negocios SET plan = 'pago', cupo_tokens_mes = ... WHERE id = 1;
--
-- El enlace viaja en el TEXTO del mensaje (HTML), no como botón: wf_enviar
-- descarta los botones sin callback_data (gen_wf_enviar.py, nodo Filas), y
-- tocar eso es abrir n8n para algo que un <a> resuelve igual.

-- =============================================================================
-- 1. Plantilla
-- =============================================================================
-- aviso_pago llega ya armado como HTML (va en `crudas`); el resto se escapa
-- como siempre.

INSERT INTO plantillas (clave, cuerpo, formato, variables, crudas, teclado) VALUES
('plan.estado',
 '📦 Tu plan: <b>{{plan}}</b>

Este mes: {{ejecuciones}} informes · {{tokens}} de {{cupo}} palabras procesadas ({{pct}}%).{{aviso_cupo}}{{aviso_pago}}',
 'html',
 '["plan","ejecuciones","tokens","cupo","pct","aviso_cupo"]'::jsonb,
 '["aviso_pago"]'::jsonb,
 '[]'::jsonb)
ON CONFLICT (clave) DO UPDATE
  SET cuerpo = EXCLUDED.cuerpo, formato = EXCLUDED.formato,
      variables = EXCLUDED.variables, crudas = EXCLUDED.crudas,
      teclado = EXCLUDED.teclado, activo = true,
      version = plantillas.version + 1;

-- =============================================================================
-- 2. router_plan
-- =============================================================================

CREATE OR REPLACE FUNCTION router_plan(p_negocio_id bigint, p_chat_id bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_plan   text;
    c        record;
    v_pct    numeric := 0;
    v_enlace text;
    v_aviso_cupo text := '';
    v_aviso_pago text := '';
BEGIN
    -- Sin negocio asignado no hay plan que mostrar.
    IF p_negocio_id IS NULL THEN
        RETURN router_respuesta(p_chat_id, 'sistema.no_entendido');
    END IF;

    SELECT plan INTO v_plan FROM negocios WHERE id = p_negocio_id;
    SELECT * INTO c FROM v_consumo_negocio WHERE negocio_id = p_negocio_id;

    IF c.cupo_tokens_mes > 0 THEN
        v_pct := round(100.0 * c.tokens_mes / c.cupo_tokens_mes);
    END IF;

    -- cupo 0 = bloqueado (regla de la 001); pasado el 80% se avisa antes de
    -- que ejecucion_preparar empiece a bloquear.
    IF c.cupo_tokens_mes = 0 THEN
        v_aviso_cupo := E'\n\n⛔ El servicio está suspendido para tu negocio.';
    ELSIF v_pct >= 100 THEN
        v_aviso_cupo := E'\n\n⛔ Superaste el cupo del mes: los análisis quedan bloqueados hasta el próximo mes o hasta ampliar el plan.';
    ELSIF v_pct >= 80 THEN
        v_aviso_cupo := E'\n\n⚠️ Vas por el ' || v_pct || '% del cupo del mes.';
    END IF;

    v_enlace := btrim(coalesce(parametro(p_negocio_id, 'pago_enlace') #>> '{}', ''));
    IF v_enlace <> '' THEN
        v_aviso_pago := E'\n\n💳 <a href="' || v_enlace ||
                        '">Pagar o ampliar el plan</a> (te lleva a Wompi, pago seguro).';
    END IF;

    RETURN router_respuesta(p_chat_id, 'plan.estado', jsonb_build_object(
        'plan', coalesce(v_plan, 'free'),
        'ejecuciones', coalesce(c.ejecuciones_mes, 0),
        'tokens', miles(coalesce(c.tokens_mes, 0)),
        'cupo', miles(coalesce(c.cupo_tokens_mes, 0)),
        'pct', v_pct,
        'aviso_cupo', v_aviso_cupo,
        'aviso_pago', v_aviso_pago));
END;
$$;

-- Separador de miles a la colombiana (punto), sin depender del lc_numeric del
-- contenedor: to_char usa ',' como grupo en locale C y acá se voltea.
CREATE OR REPLACE FUNCTION miles(p numeric)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT replace(to_char(round(coalesce(p, 0)), 'FM999,999,999,999'), ',', '.');
$$;

-- =============================================================================
-- 3. Router v6: idéntico al de la 033 salvo el bloque /plan marcado abajo
-- =============================================================================

CREATE OR REPLACE FUNCTION router_procesar_mensaje(p_evento jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_usuario_id bigint;
    v_chat_id    bigint  := (p_evento #>> '{chat,id}')::bigint;
    v_texto      text    := btrim(coalesce(p_evento ->> 'texto', ''));
    v_cmd        text;
    v_svc        text;          -- código que llegó por botón (svc:<codigo>)
    v_arg        text;          -- resto del mensaje después del comando
    v_tiene_doc  boolean := coalesce((p_evento ->> 'tiene_documento')::boolean, false);
    v_sesion     record;
    v_negocio_id bigint;
    v_autoriz    boolean;
    v_rol        rol_usuario;
    v_servicio   record;
    v_n_serv     int;
    v_consulta   boolean;
    v_ejec_id    bigint;
    v_nueva_ses  bigint;
    v_titulo     text;
BEGIN
    -- El primer token y el resto. Se parte por espacio EN BLANCO, no por ' ':
    -- un "/saber" seguido de salto de línea es la forma natural de enseñarle
    -- algo largo, y con split_part(' ') el comando se comía el texto entero.
    v_cmd := lower(coalesce(substring(v_texto FROM '^\S+'), ''));
    v_arg := btrim(coalesce(substring(v_texto FROM '^\S+\s+(.*)$'), ''));
    IF v_texto LIKE 'svc:%' THEN
        v_svc := substring(v_texto FROM 5);
        v_cmd := 'svc';
    END IF;

    v_usuario_id := usuario_de_canal('telegram', p_evento);
    SELECT negocio_id, autorizacion_datos, rol
      INTO v_negocio_id, v_autoriz, v_rol
    FROM usuarios WHERE id = v_usuario_id;

    -- Solo los de archivos: los de texto no se eligen de una lista.
    SELECT count(*) INTO v_n_serv
    FROM servicios WHERE activo AND entrada = 'archivos';
    SELECT EXISTS (SELECT 1 FROM servicios WHERE activo AND entrada = 'texto'
                     AND codigo = 'consulta') INTO v_consulta;

    -- ---- Comandos de admin -------------------------------------------------
    IF v_cmd IN ('/salud','/embudo','/fallas','/consumo','/matching','/admin') THEN
        IF v_rol <> 'admin' THEN
            RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
        END IF;
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

    -- ---- /portal: el enlace de un solo uso ---------------------------------
    -- Todo lo que necesite más de un turno o más de un campo vive allá; en el
    -- chat es un enlace y nada más.
    IF v_cmd IN ('/portal','/web') THEN
        RETURN router_portal(v_usuario_id, v_chat_id);
    END IF;

    -- >>> Lo nuevo de la 041: /plan. Plan, consumo del mes y enlace de pago si
    -- el operador lo configuró (parametros 'pago_enlace' del negocio).
    IF v_cmd = '/plan' THEN
        RETURN router_plan(v_negocio_id, v_chat_id);
    END IF;

    -- ---- /saber: el dueño le enseña algo al bot ----------------------------
    -- Sin tipo ni clave: lo que entra por chat es un hecho suelto. Clasificarlo
    -- y darle estructura es trabajo del portal, que tiene pantalla para eso.
    IF v_cmd = '/saber' THEN
        -- Sin negocio asignado no hay dónde guardar el hecho; el usuario
        -- tampoco puede hacer nada más en el bot hasta que se lo asignen.
        IF v_negocio_id IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
        END IF;
        IF v_arg = '' THEN
            RETURN router_respuesta(v_chat_id, 'conocimiento.saber_vacio');
        END IF;
        -- El título es la primera frase (o los primeros 80 caracteres): es lo
        -- que se muestra en las listas y lo que más pesa en la búsqueda.
        v_titulo := btrim(split_part(v_arg, '.', 1));
        IF char_length(v_titulo) > 80 OR v_titulo = '' THEN
            v_titulo := btrim(left(v_arg, 80));
        END IF;
        PERFORM conocimiento_guardar(v_negocio_id, 'faq', v_titulo, v_arg,
                                     NULL, '{}'::jsonb, 'chat', v_usuario_id);
        RETURN router_respuesta(v_chat_id, 'conocimiento.guardado',
                 jsonb_build_object('titulo', v_titulo));
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

        IF v_n_serv = 1 THEN
            SELECT * INTO v_servicio FROM servicios
            WHERE activo AND entrada = 'archivos' LIMIT 1;
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
        IF v_tiene_doc AND v_n_serv = 1 THEN
            SELECT * INTO v_servicio FROM servicios
            WHERE activo AND entrada = 'archivos' LIMIT 1;
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

        -- Texto libre = pregunta. Va último a propósito: cualquier cosa que
        -- empiece con '/' es un comando que no existe, no una pregunta, y un
        -- 'svc:' es un botón rancio del historial.
        IF v_consulta AND v_texto <> '' AND left(v_texto, 1) <> '/' AND v_cmd <> 'svc' THEN
            RETURN consulta_iniciar(v_usuario_id, v_negocio_id, v_chat_id, v_texto);
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
            SELECT * INTO v_servicio FROM servicios
            WHERE activo AND entrada = 'archivos' AND codigo = v_svc;
        ELSIF v_tiene_doc AND v_n_serv = 1 THEN
            SELECT * INTO v_servicio FROM servicios
            WHERE activo AND entrada = 'archivos' LIMIT 1;
        ELSE
            SELECT * INTO v_servicio FROM servicios
            WHERE activo AND entrada = 'archivos'
              AND (norm_texto(nombre) LIKE '%'||norm_texto(v_texto)||'%'
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
    -- Acá el texto libre NO se desvía a consulta: el usuario está a mitad de un
    -- análisis y secuestrarle el turno con una respuesta de la KB haría perder
    -- los archivos que ya subió.
    IF v_sesion.estado = 'recibiendo' THEN
        IF v_tiene_doc THEN
            RETURN router_respuesta(v_chat_id, NULL, NULL, NULL,
                     jsonb_build_array(jsonb_build_object(
                       'tipo','ingerir','sesion_id', v_sesion.id)));
        END IF;

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
