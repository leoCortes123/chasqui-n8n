-- 042_confirmar_carga.sql — la carga se confirma una vez, no archivo por archivo.
--
-- Antes cada archivo bien cargado contestaba con su resumen y dos botones
-- (Analizar / Cancelar). Mandando varios archivos eso era una metralleta de
-- mensajes iguales y confundía. Ahora:
--   * un archivo que carga bien no contesta nada: wf_ingesta espera unos
--     segundos y, si no entró otro archivo, pregunta "¿son todos?";
--   * Sí (/todos)  -> UN solo resumen de la sesión con Generar informe / Cancelar;
--   * No (/faltan) -> seguimos esperando archivos, sin botones de por medio.
-- Los errores por archivo se siguen avisando al momento: eso sí es urgente.
-- También desaparece el botón "Analizar otra vez" del informe entregado.

-- === Plantillas =============================================================

INSERT INTO plantillas (clave, cuerpo, variables, teclado) VALUES
  ('ingesta.todos_archivos',
   '¿Ya me mandaste todos los archivos?',
   '[]',
   '[[{"dato": "/todos",  "texto": "✅ Sí, son todos"}],
     [{"dato": "/faltan", "texto": "➕ Voy a mandar más"}]]'),
  ('ingesta.resumen_sesion',
   'Esto fue lo que cargué:

{{detalle}}

Total: {{total}}{{aviso_nit}}',
   '["archivos","detalle","total","aviso_nit"]',
   '[[{"dato": "/listo",    "texto": "📊 Generar informe"}],
     [{"dato": "/cancelar", "texto": "✖️ Cancelar"}]]'),
  ('ingesta.esperando_mas',
   'Dale, espero los que faltan.',
   '[]', '[]')
ON CONFLICT (clave) DO UPDATE
  SET cuerpo = EXCLUDED.cuerpo, variables = EXCLUDED.variables,
      teclado = EXCLUDED.teclado, version = plantillas.version + 1;

-- El informe entregado ya no ofrece "Analizar otra vez".
UPDATE plantillas SET teclado = '[]'::jsonb, version = version + 1
WHERE clave = 'ejecucion.entregada';

-- === Resumen de toda la sesión ==============================================
-- Lo que ingesta_resumen_documento cuenta de un archivo, acá agregado: una
-- línea por documento parseado y el total general. Texto plano a propósito:
-- resolver_plantilla escapa las variables (022), así que nada de HTML acá.

CREATE OR REPLACE FUNCTION ingesta_resumen_sesion(p_sesion_id bigint)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    WITH docs AS (
        SELECT d.id, d.nombre_archivo,
               (SELECT count(*) FROM movimientos m WHERE m.documento_id = d.id) AS filas,
               (SELECT round(coalesce(sum(m.valor_total), 0))
                  FROM movimientos m WHERE m.documento_id = d.id)               AS total
        FROM documentos d
        WHERE d.sesion_id = p_sesion_id AND d.estado = 'parseado'
    )
    SELECT jsonb_build_object(
        'archivos', (SELECT count(*) FROM docs),
        'detalle',  coalesce((SELECT string_agg(
                        format('📄 %s: %s registros, $%s',
                               nombre_archivo, filas, miles(total)),
                        E'\n' ORDER BY id) FROM docs), ''),
        'total',    '$' || miles((SELECT coalesce(sum(total), 0) FROM docs)),
        -- Mismo criterio que ingesta_resumen_documento (038): hubo factura y
        -- el negocio no tiene NIT -> no se pudo saber de qué lado del
        -- mostrador está.
        'aviso_nit', CASE WHEN EXISTS (
                            SELECT 1 FROM facturas f
                            JOIN documentos d ON d.id = f.documento_id
                            WHERE d.sesion_id = p_sesion_id)
                          AND (SELECT nullif(btrim(coalesce(n.nit, '')), '')
                                 FROM negocios n
                                 JOIN sesiones s ON s.negocio_id = n.id
                                WHERE s.id = p_sesion_id) IS NULL
                     THEN E'\n\n💡 Las facturas las tomé como compras porque no tengo el NIT de tu negocio. Cargalo en tu /portal (Mi negocio) y sabré cuáles son tuyas.'
                     ELSE '' END
    );
$$;

-- === Router =================================================================
-- Copia de la 041 con un solo agregado: /todos y /faltan dentro del estado
-- 'recibiendo', antes de /listo.

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

    -- Plan, consumo del mes y enlace de pago si el operador lo configuró.
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

        -- >>> Lo nuevo de la 042: la pregunta "¿son todos?" se contesta acá.
        -- Sí -> el único resumen de la carga, con los botones de verdad.
        IF v_cmd = '/todos' THEN
            IF NOT EXISTS (SELECT 1 FROM documentos
                           WHERE sesion_id = v_sesion.id AND estado = 'parseado') THEN
                RETURN router_respuesta(v_chat_id, 'sistema.sin_documentos');
            END IF;
            RETURN router_respuesta(v_chat_id, 'ingesta.resumen_sesion',
                     ingesta_resumen_sesion(v_sesion.id));
        END IF;
        -- No -> a seguir esperando archivos, sin más botones.
        IF v_cmd = '/faltan' THEN
            RETURN router_respuesta(v_chat_id, 'ingesta.esperando_mas');
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
