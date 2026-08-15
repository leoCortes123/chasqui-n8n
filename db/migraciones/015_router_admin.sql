-- 015_router_admin.sql — comandos de operación dentro de la misma máquina de
-- estados, restringidos por usuarios.rol. Cero workflow nuevo: el admin entra
-- por el mismo webhook que todos y router_procesar_mensaje lo atiende antes de
-- la lógica de conversación.

-- Formatea las vistas de observabilidad como texto para Telegram.
CREATE FUNCTION admin_reporte(p_cmd text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE v text;
BEGIN
    IF p_cmd = '/salud' THEN
        SELECT coalesce(string_agg(format('%s/%s · %s: %s docs (err %s%%)',
                 negocio_id, formato_codigo, estado, documentos,
                 coalesce(pct_error_formato,0)), E'\n'), 'sin documentos')
        INTO v FROM v_salud_ingesta;
        RETURN '🩺 *Salud de ingesta*' || E'\n' || v;

    ELSIF p_cmd = '/embudo' THEN
        SELECT coalesce(string_agg(format('%s: %s iniciadas, %s completas, %s abandonadas, %s fallidas (cae en: %s)',
                 servicio_codigo, iniciadas, completadas, abandonadas, fallidas,
                 coalesce(paso_de_caida,'-')), E'\n'), 'sin sesiones')
        INTO v FROM v_embudo_servicios;
        RETURN '🫗 *Embudo de servicios*' || E'\n' || v;

    ELSIF p_cmd = '/fallas' THEN
        SELECT coalesce(string_agg(format('#%s %s · %s · %s',
                 ejecucion_id, servicio_codigo, to_char(inicio,'DD/MM HH24:MI'),
                 left(coalesce(error,''),60)), E'\n'), 'sin fallas en 24h')
        INTO v FROM v_ejecuciones_fallidas;
        RETURN '🔧 *Fallas (24h)*' || E'\n' || v;

    ELSIF p_cmd = '/consumo' THEN
        SELECT coalesce(string_agg(format('%s: %s tokens, $%s, %s ejec.',
                 nombre, tokens_mes, round(costo_mes,2), ejecuciones_mes), E'\n'), 'sin consumo')
        INTO v FROM v_consumo_negocio;
        RETURN '💰 *Consumo del mes*' || E'\n' || v;

    ELSIF p_cmd = '/matching' THEN
        SELECT coalesce(string_agg(format('negocio %s: %s%% resuelto (%s pendientes)',
                 negocio_id, coalesce(pct_resuelto,0), pendientes), E'\n'), 'sin datos')
        INTO v FROM v_calidad_matching;
        RETURN '🔗 *Calidad de matching*' || E'\n' || v;

    ELSE
        RETURN '📋 Comandos: /salud /embudo /fallas /consumo /matching';
    END IF;
END;
$$;

-- Intercepta comandos de admin al inicio de router_procesar_mensaje.
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
    v_resp       jsonb := '[]';
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
                'plantilla','sistema.no_entendido','vars','{}')), 'acciones','[]');
        END IF;
        RETURN jsonb_build_object('chat_id', v_chat_id,
          'respuestas', jsonb_build_array(jsonb_build_object(
            'plantilla', admin_reporte(v_cmd), 'vars', '{}')), 'acciones','[]');
    END IF;

    SELECT * INTO v_sesion FROM sesiones
    WHERE usuario_id = v_usuario_id AND cerrada_en IS NULL
    ORDER BY id DESC LIMIT 1;
    IF FOUND THEN
        UPDATE sesiones SET ultima_actividad = now() WHERE id = v_sesion.id;
    END IF;

    IF v_cmd IN ('/start','/help','/ayuda') THEN
        RETURN jsonb_build_object('chat_id', v_chat_id,
            'respuestas', jsonb_build_array(jsonb_build_object('plantilla','sistema.bienvenida','vars','{}')),
            'acciones','[]');
    END IF;

    IF NOT v_autoriz THEN
        IF lower(v_texto) IN ('acepto','autorizo','si','sí') THEN
            UPDATE usuarios SET autorizacion_datos=true, autorizacion_fecha=now() WHERE id=v_usuario_id;
            RETURN jsonb_build_object('chat_id', v_chat_id,
              'respuestas', jsonb_build_array(jsonb_build_object('plantilla','sistema.bienvenida','vars','{}')), 'acciones','[]');
        ELSE
            RETURN jsonb_build_object('chat_id', v_chat_id,
              'respuestas', jsonb_build_array(jsonb_build_object('plantilla','sistema.no_autorizado','vars','{}')), 'acciones','[]');
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
          'acciones','[]');
    END IF;

    IF v_sesion.id IS NULL THEN
        RETURN jsonb_build_object('chat_id', v_chat_id,
          'respuestas', jsonb_build_array(jsonb_build_object('plantilla','sistema.sin_sesion','vars','{}')), 'acciones','[]');
    END IF;

    IF v_sesion.estado='intake' AND v_sesion.paso='elegir_servicio' THEN
        SELECT * INTO v_servicio FROM servicios
        WHERE activo AND (norm_texto(nombre) LIKE '%'||norm_texto(v_texto)||'%'
                          OR norm_texto(v_texto) LIKE '%'||norm_texto(nombre)||'%'
                          OR codigo = lower(v_texto))
        ORDER BY orden LIMIT 1;
        IF v_servicio.codigo IS NULL THEN
            RETURN jsonb_build_object('chat_id', v_chat_id,
              'respuestas', jsonb_build_array(jsonb_build_object('plantilla','sistema.servicio_no_reconocido','vars','{}')), 'acciones','[]');
        END IF;
        UPDATE sesiones SET servicio_codigo=v_servicio.codigo, estado='recibiendo', paso='cargar_archivos' WHERE id=v_sesion.id;
        RETURN jsonb_build_object('chat_id', v_chat_id,
          'respuestas', jsonb_build_array(jsonb_build_object('plantilla','sistema.pedir_archivos',
            'vars', jsonb_build_object('servicio', v_servicio.nombre))), 'acciones','[]');
    END IF;

    IF v_sesion.estado='recibiendo' THEN
        IF v_tiene_doc THEN
            RETURN jsonb_build_object('chat_id', v_chat_id, 'respuestas','[]',
              'acciones', jsonb_build_array(jsonb_build_object('tipo','ingerir','sesion_id',v_sesion.id)));
        END IF;
        IF v_cmd IN ('/listo','/analizar','/fin') THEN
            IF NOT EXISTS (SELECT 1 FROM documentos WHERE sesion_id=v_sesion.id AND estado='parseado') THEN
                RETURN jsonb_build_object('chat_id', v_chat_id,
                  'respuestas', jsonb_build_array(jsonb_build_object('plantilla','sistema.sin_documentos','vars','{}')), 'acciones','[]');
            END IF;
            UPDATE sesiones SET estado='procesando', paso='ejecutando' WHERE id=v_sesion.id;
            INSERT INTO ejecuciones (sesion_id, negocio_id, servicio_codigo, estado)
            VALUES (v_sesion.id, v_negocio_id, v_sesion.servicio_codigo, 'preparando')
            RETURNING id INTO v_ejec_id;
            RETURN jsonb_build_object('chat_id', v_chat_id,
              'respuestas', jsonb_build_array(jsonb_build_object('plantilla','ejecucion.en_curso','vars','{}')),
              'acciones', jsonb_build_array(jsonb_build_object('tipo','ejecutar','ejecucion_id',v_ejec_id)));
        END IF;
        RETURN jsonb_build_object('chat_id', v_chat_id,
          'respuestas', jsonb_build_array(jsonb_build_object('plantilla','sistema.esperando_listo','vars','{}')), 'acciones','[]');
    END IF;

    RETURN jsonb_build_object('chat_id', v_chat_id,
      'respuestas', jsonb_build_array(jsonb_build_object('plantilla','sistema.no_entendido','vars','{}')), 'acciones','[]');
END;
$$;
