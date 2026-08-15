-- 056_router_modular.sql — se acaban las copias de 300 líneas.
--
-- EL PROBLEMA (H5). `router_procesar_mensaje` va por su OCTAVA copia íntegra:
-- 012, 015, 016, 024, 030, 033, 041, 042, 043, 045, 046, 051, 053. Cada vez que
-- una migración necesitaba cambiar seis líneas del router, tenía que pegar las
-- otras trescientas. No es un problema estético: **ya se perdió un fix por ese
-- mecanismo**. El `periodo` que la 046 agregó a `ingesta_resumen_sesion` con
-- justificación explícita lo borró la 051 sin mencionarlo, simplemente porque
-- pegó una versión anterior encima.
--
-- Todas las fases que vienen tocan el router: C1 (preguntar a los números),
-- D1 (botones sobre la recomendación), F2. Con el router monolítico, cada una
-- paga el impuesto de la copia íntegra y arriesga repetir esa regresión.
--
-- LA FORMA. Un despachador delgado y handlers por estado. Cada migración futura
-- reemplaza UN handler —el que le toca— y las otras tres quedan intactas en la
-- base, sin que nadie tenga que volver a escribirlas.
--
--   router_ctx           parseo del mensaje + identidad + capacidades del sistema
--   router_h_admin       los reportes de admin
--   router_h_comandos    comandos y botones que no dependen del estado
--   router_h_sin_sesion  no hay conversación abierta
--   router_h_intake      hay sesión, falta elegir servicio
--   router_h_recibiendo  hay servicio, entran archivos
--
-- EL CONTRATO, que es lo único nuevo que hay que aprender:
--
--   * Todos los handlers reciben **un solo argumento**, `p_ctx jsonb`, con todo
--     ya resuelto. Se eligió jsonb sobre quince parámetros posicionales por una
--     razón concreta: agregarle un dato al contexto (un canal, un flag, un
--     estado nuevo) NO cambia ninguna firma, así que no obliga a un DROP en
--     cascada ni a repuntar los handlers que no se enteraron. Es el mismo patrón
--     de `servicios.funcion_hallazgos` y de `plantillas`: el contrato es un dato,
--     no una signatura.
--
--   * Un handler devuelve **NULL** para decir "esto no me toca, seguí". Es
--     seguro: `router_respuesta` construye siempre un objeto, nunca NULL, ni
--     siquiera cuando la respuesta no lleva texto (el caso `ingerir`, que
--     devuelve solo acciones). O sea que NULL no puede confundirse con una
--     respuesta legítima.
--
-- QUÉ NO CAMBIA: el comportamiento. Ni una rama nueva, ni una plantilla nueva,
-- ni un orden distinto. Los cuerpos de cada rama se mudaron literalmente desde
-- la 053. En particular se conserva un detalle fácil de perder al reordenar:
-- **el bloque de admin corre ANTES de leer la sesión**, y por eso un `/salud`
-- no le refresca `ultima_actividad` a una sesión que estaba por expirar. Por eso
-- `router_h_admin` es un handler aparte y no una rama más de `router_h_comandos`
-- (el roadmap listaba cuatro handlers; son cinco por esto).
--
-- Tampoco cambia nada en n8n: `wf_router` y `wf_wa_router` siguen haciendo una
-- sola llamada a `router_procesar_mensaje(evento)`, que sigue existiendo con la
-- misma firma y el mismo contrato de salida.

-- =============================================================================
-- 1. El contexto: todo lo que el router necesita saber antes de decidir
-- =============================================================================
-- Se arma una sola vez por mensaje. No incluye la sesión a propósito: la sesión
-- se lee después del handler de admin (ver arriba) y el despachador la agrega
-- con `||`.
CREATE OR REPLACE FUNCTION router_ctx(p_evento jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_usuario_id bigint;
    v_texto      text := btrim(coalesce(p_evento ->> 'texto', ''));
    v_cmd        text;
    v_arg        text;          -- resto del mensaje después del comando
    v_svc        text;          -- código que llegó por botón (svc:<codigo>)
    v_mod        text;          -- código de módulo (mod:/modayuda:)
    v_tip        text;          -- >>> 046: naturaleza del negocio (tipo:<codigo>)
    v_negocio_id bigint;
    v_autoriz    boolean;
    v_rol        rol_usuario;
    v_n_serv     int;
    v_consulta   boolean;
BEGIN
    -- El primer token y el resto. Se parte por espacio EN BLANCO, no por ' ':
    -- un "/saber" seguido de salto de línea es la forma natural de enseñarle
    -- algo largo, y con split_part(' ') el comando se comía el texto entero.
    v_cmd := lower(coalesce(substring(v_texto FROM '^\S+'), ''));
    v_arg := btrim(coalesce(substring(v_texto FROM '^\S+\s+(.*)$'), ''));
    IF v_texto LIKE 'svc:%' THEN
        v_svc := substring(v_texto FROM 5);
        v_cmd := 'svc';
    ELSIF v_texto LIKE 'mod:%' THEN
        v_mod := substring(v_texto FROM 5);
        v_cmd := 'mod';
    ELSIF v_texto LIKE 'modayuda:%' THEN
        v_mod := substring(v_texto FROM 10);
        v_cmd := 'modayuda';
    ELSIF v_texto LIKE 'tipo:%' THEN
        v_tip := substring(v_texto FROM 6);
        v_cmd := 'tipo';
    ELSIF v_texto LIKE 'acepto:%' THEN
        -- >>> 051: 'acepto:<mensaje original>' — el consentimiento se lleva
        -- puesto el paso que lo disparó para poder retomarlo.
        v_arg := btrim(substring(v_texto FROM 8));
        v_cmd := 'acepto';
    END IF;

    -- El canal por defecto es telegram; el evento puede declarar otro (044).
    -- Acá también se crea el usuario y su negocio si es la primera vez (050).
    v_usuario_id := usuario_de_canal('telegram', p_evento);
    SELECT negocio_id, autorizacion_datos, rol
      INTO v_negocio_id, v_autoriz, v_rol
    FROM usuarios WHERE id = v_usuario_id;

    -- Solo los de archivos: los de texto no se eligen de una lista.
    SELECT count(*) INTO v_n_serv
    FROM servicios WHERE activo AND entrada = 'archivos';
    SELECT EXISTS (SELECT 1 FROM servicios WHERE activo AND entrada = 'texto'
                     AND codigo = 'consulta') INTO v_consulta;

    RETURN jsonb_build_object(
        'evento',     p_evento,
        'chat_id',    (p_evento #>> '{chat,id}')::bigint,
        'usuario_id', v_usuario_id,
        'negocio_id', v_negocio_id,
        'rol',        v_rol::text,
        'autoriz',    coalesce(v_autoriz, false),
        'texto',      v_texto,
        'cmd',        v_cmd,
        'arg',        v_arg,
        'svc',        v_svc,
        'mod',        v_mod,
        'tip',        v_tip,
        'tiene_doc',  coalesce((p_evento ->> 'tiene_documento')::boolean, false),
        'n_serv',     v_n_serv,
        'consulta',   v_consulta);
END;
$$;

-- =============================================================================
-- 2. Handler: reportes de admin
-- =============================================================================
-- Corre antes de que se lea la sesión, y por eso vive aparte.
CREATE OR REPLACE FUNCTION router_h_admin(p_ctx jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_chat_id bigint := (p_ctx ->> 'chat_id')::bigint;
    v_cmd     text   := p_ctx ->> 'cmd';
BEGIN
    IF v_cmd NOT IN ('/salud','/embudo','/fallas','/consumo','/matching','/admin') THEN
        RETURN NULL;
    END IF;
    IF (p_ctx ->> 'rol') IS DISTINCT FROM 'admin' THEN
        RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
    END IF;
    RETURN router_respuesta(v_chat_id, admin_reporte(v_cmd));
END;
$$;

-- =============================================================================
-- 3. Handler: comandos y botones independientes del estado
-- =============================================================================
-- Todo lo que se puede contestar sin preguntarle a la sesión en qué paso va.
-- El orden interno importa y es el de siempre; los comentarios que lo explican
-- vienen de las migraciones que lo establecieron.
CREATE OR REPLACE FUNCTION router_h_comandos(p_ctx jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_chat_id    bigint  := (p_ctx ->> 'chat_id')::bigint;
    v_usuario_id bigint  := (p_ctx ->> 'usuario_id')::bigint;
    v_negocio_id bigint  := (p_ctx ->> 'negocio_id')::bigint;
    v_texto      text    := p_ctx ->> 'texto';
    v_cmd        text    := p_ctx ->> 'cmd';
    v_arg        text    := coalesce(p_ctx ->> 'arg', '');
    v_svc        text    := p_ctx ->> 'svc';
    v_mod        text    := p_ctx ->> 'mod';
    v_tip        text    := p_ctx ->> 'tip';
    v_autoriz    boolean := (p_ctx ->> 'autoriz')::boolean;
    v_n_serv     int     := (p_ctx ->> 'n_serv')::int;
    v_ses_id     bigint  := (p_ctx ->> 'sesion_id')::bigint;
    v_ses_estado text    := p_ctx ->> 'sesion_estado';
    v_ses_srv    text    := p_ctx ->> 'sesion_servicio';
    v_servicio   record;
    v_modulo     record;
    v_titulo     text;
BEGIN
    -- ---- Informativos: accesibles incluso sin autorizar --------------------
    IF v_cmd IN ('/start','/help','/ayuda') THEN
        RETURN router_respuesta(v_chat_id, 'sistema.bienvenida');   -- >>> 046
    END IF;
    IF v_cmd = '/comofunciona' THEN
        RETURN router_respuesta(v_chat_id, 'sistema.como_funciona');
    END IF;
    IF v_cmd = '/privacidad' THEN
        RETURN router_respuesta(v_chat_id, 'sistema.privacidad');
    END IF;

    -- ---- Módulos: son un menú, no tocan un solo dato -----------------------
    -- >>> 051: van ANTES del consentimiento a propósito. Mirar la lista de lo
    -- que el asistente sabe hacer no requiere autorizar nada; el permiso se
    -- pide justo cuando se elige una opción, que es cuando se van a entregar
    -- datos del negocio. Pedirlo antes es pedirlo a ciegas.
    IF v_cmd = 'mod' THEN
        SELECT * INTO v_modulo FROM modulos WHERE activo AND codigo = v_mod;
        IF v_modulo.codigo IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.bienvenida');
        END IF;
        RETURN router_respuesta(v_chat_id, 'sistema.modulo',
                 jsonb_build_object('titular', v_modulo.titular),
                 teclado_modulo(v_modulo.codigo));
    END IF;

    IF v_cmd = 'modayuda' THEN
        SELECT * INTO v_modulo FROM modulos WHERE activo AND codigo = v_mod;
        IF v_modulo.codigo IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.bienvenida');
        END IF;
        RETURN router_respuesta(v_chat_id, 'sistema.modulo_ayuda',
                 jsonb_build_object('ayuda', v_modulo.ayuda),
                 teclado_modulo(v_modulo.codigo));
    END IF;

    -- ---- >>> 051: "Acepto" con memoria de lo que se estaba haciendo --------
    -- El botón del consentimiento manda 'acepto:<lo que el usuario había
    -- tocado>'. Se registra el permiso y se vuelve a despachar ESE mensaje, ya
    -- autorizado: el usuario cae exactamente donde iba, no en la bienvenida.
    -- No hay recursión infinita porque la autorización ya quedó en true.
    IF v_cmd = 'acepto' OR
       (NOT v_autoriz AND lower(v_texto) IN ('acepto','autorizo','si','sí','ok','dale')) THEN
        UPDATE usuarios SET autorizacion_datos = true, autorizacion_fecha = now()
        WHERE id = v_usuario_id;
        IF v_cmd = 'acepto' AND v_arg <> '' THEN
            RETURN router_procesar_mensaje(
                     (p_ctx -> 'evento') || jsonb_build_object('texto', v_arg));
        END IF;
        RETURN router_respuesta(v_chat_id, 'sistema.bienvenida');
    END IF;

    -- ---- Consentimiento de datos (una sola vez) ----------------------------
    -- Lo que el usuario tocó viaja en el botón para poder retomarlo al aceptar.
    IF NOT v_autoriz THEN
        RETURN router_respuesta(v_chat_id, 'sistema.consentimiento',
                 jsonb_build_object('meses',
                   coalesce((parametro(NULL, 'plan_free_meses_historia'))::text, '3')),
                 teclado_consentimiento(v_texto));
    END IF;

    -- ---- >>> 046: naturaleza del negocio -----------------------------------
    -- Se contesta una vez y sigue el camino que estaba interrumpido. Un botón
    -- viejo del historial vuelve a guardar lo mismo: es idempotente.
    IF v_cmd = 'tipo' THEN
        IF v_negocio_id IS NULL
           OR NOT EXISTS (SELECT 1 FROM tipos_negocio WHERE activo AND codigo = v_tip) THEN
            RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
        END IF;
        UPDATE negocios SET tipo = v_tip WHERE id = v_negocio_id;

        IF v_ses_id IS NOT NULL AND v_ses_srv IS NOT NULL THEN
            RETURN router_arranque_servicio(v_negocio_id, v_chat_id, v_ses_srv);
        END IF;
        RETURN router_respuesta(v_chat_id, 'sistema.bienvenida');
    END IF;

    -- ---- /portal: el enlace de un solo uso ---------------------------------
    IF v_cmd IN ('/portal','/web') THEN
        RETURN router_portal(v_usuario_id, v_chat_id);
    END IF;

    -- Plan, consumo del mes y enlace de pago si el operador lo configuró.
    IF v_cmd = '/plan' THEN
        RETURN router_plan(v_negocio_id, v_chat_id);
    END IF;

    -- ---- /saber: el dueño le enseña algo al bot ----------------------------
    IF v_cmd = '/saber' THEN
        IF v_negocio_id IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
        END IF;
        IF v_arg = '' THEN
            RETURN router_respuesta(v_chat_id, 'conocimiento.saber_vacio');
        END IF;
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
        IF v_ses_id IS NULL THEN
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
            RETURN router_arranque_servicio(v_negocio_id, v_chat_id, v_servicio.codigo);
        END IF;

        INSERT INTO sesiones (usuario_id, negocio_id, estado, paso)
        VALUES (v_usuario_id, v_negocio_id, 'intake', 'elegir_servicio');
        RETURN router_respuesta(v_chat_id, 'sistema.elegir_servicio',
                 '{}'::jsonb, teclado_servicios());
    END IF;

    -- ---- Servicio elegido desde el menú (045) ------------------------------
    IF v_cmd = 'svc' AND (v_ses_id IS NULL OR v_ses_estado = 'intake') THEN
        SELECT * INTO v_servicio FROM servicios
        WHERE activo AND entrada = 'archivos' AND codigo = v_svc;

        IF v_servicio.codigo IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.servicio_no_reconocido',
                     '{}'::jsonb, teclado_servicios());
        END IF;

        IF v_ses_id IS NULL THEN
            INSERT INTO sesiones (usuario_id, negocio_id, servicio_codigo, estado, paso)
            VALUES (v_usuario_id, v_negocio_id, v_servicio.codigo,
                    'recibiendo', 'cargar_archivos');
        ELSE
            UPDATE sesiones SET servicio_codigo = v_servicio.codigo,
                   estado = 'recibiendo', paso = 'cargar_archivos'
            WHERE id = v_ses_id;
        END IF;

        RETURN router_arranque_servicio(v_negocio_id, v_chat_id, v_servicio.codigo);
    END IF;

    RETURN NULL;   -- no me toca: que decida el estado de la sesión
END;
$$;

-- =============================================================================
-- 4. Handler: no hay conversación abierta
-- =============================================================================
CREATE OR REPLACE FUNCTION router_h_sin_sesion(p_ctx jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_chat_id    bigint  := (p_ctx ->> 'chat_id')::bigint;
    v_usuario_id bigint  := (p_ctx ->> 'usuario_id')::bigint;
    v_negocio_id bigint  := (p_ctx ->> 'negocio_id')::bigint;
    v_texto      text    := p_ctx ->> 'texto';
    v_cmd        text    := p_ctx ->> 'cmd';
    v_tiene_doc  boolean := (p_ctx ->> 'tiene_doc')::boolean;
    v_n_serv     int     := (p_ctx ->> 'n_serv')::int;
    v_consulta   boolean := (p_ctx ->> 'consulta')::boolean;
    v_servicio   record;
    v_nueva_ses  bigint;
BEGIN
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
END;
$$;

-- =============================================================================
-- 5. Handler: intake — hay sesión, falta elegir servicio
-- =============================================================================
-- Queda para el nombre escrito a mano y para el archivo mandado antes de
-- elegir; el botón `svc:` ya lo resolvió `router_h_comandos`.
CREATE OR REPLACE FUNCTION router_h_intake(p_ctx jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_chat_id    bigint  := (p_ctx ->> 'chat_id')::bigint;
    v_negocio_id bigint  := (p_ctx ->> 'negocio_id')::bigint;
    v_texto      text    := p_ctx ->> 'texto';
    v_tiene_doc  boolean := (p_ctx ->> 'tiene_doc')::boolean;
    v_n_serv     int     := (p_ctx ->> 'n_serv')::int;
    v_ses_id     bigint  := (p_ctx ->> 'sesion_id')::bigint;
    v_servicio   record;
BEGIN
    -- Un paso que no sea 'elegir_servicio' no es asunto de este handler.
    IF (p_ctx ->> 'sesion_paso') IS DISTINCT FROM 'elegir_servicio' THEN
        RETURN NULL;
    END IF;

    IF v_tiene_doc AND v_n_serv = 1 THEN
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
           paso = 'cargar_archivos' WHERE id = v_ses_id;

    IF v_tiene_doc THEN
        RETURN router_respuesta(v_chat_id, NULL, NULL, NULL,
                 jsonb_build_array(jsonb_build_object(
                   'tipo','ingerir','sesion_id', v_ses_id)));
    END IF;

    RETURN router_arranque_servicio(v_negocio_id, v_chat_id, v_servicio.codigo);
END;
$$;

-- =============================================================================
-- 6. Handler: recibiendo archivos
-- =============================================================================
-- Acá el texto libre NO se desvía a consulta: el usuario está a mitad de un
-- análisis y secuestrarle el turno con una respuesta de la KB haría perder
-- los archivos que ya subió.
CREATE OR REPLACE FUNCTION router_h_recibiendo(p_ctx jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_chat_id    bigint  := (p_ctx ->> 'chat_id')::bigint;
    v_negocio_id bigint  := (p_ctx ->> 'negocio_id')::bigint;
    v_cmd        text    := p_ctx ->> 'cmd';
    v_tiene_doc  boolean := (p_ctx ->> 'tiene_doc')::boolean;
    v_ses_id     bigint  := (p_ctx ->> 'sesion_id')::bigint;
    v_ses_srv    text    := p_ctx ->> 'sesion_servicio';
    v_ejec_id    bigint;
BEGIN
    IF v_tiene_doc THEN
        RETURN router_respuesta(v_chat_id, NULL, NULL, NULL,
                 jsonb_build_array(jsonb_build_object(
                   'tipo','ingerir','sesion_id', v_ses_id)));
    END IF;

    IF v_cmd = 'svc' THEN
        RETURN router_respuesta(v_chat_id, 'sistema.servicio_ya_elegido',
                 jsonb_build_object('servicio',
                   (SELECT nombre FROM servicios WHERE codigo = v_ses_srv)));
    END IF;

    -- La pregunta "¿son todos?" se contesta acá (042).
    IF v_cmd = '/todos' THEN
        IF NOT EXISTS (SELECT 1 FROM documentos
                       WHERE sesion_id = v_ses_id AND estado = 'parseado') THEN
            RETURN router_respuesta(v_chat_id, 'sistema.sin_documentos');
        END IF;
        RETURN router_respuesta(v_chat_id, 'ingesta.resumen_sesion',
                 ingesta_resumen_sesion(v_ses_id));
    END IF;
    IF v_cmd = '/faltan' THEN
        RETURN router_respuesta(v_chat_id, 'ingesta.esperando_mas');
    END IF;

    IF v_cmd IN ('/listo','/analizar','/fin') THEN
        -- mercado_compras puede correr sin archivos en la sesión si el
        -- negocio ya tiene compras cargadas de antes (043). La compuerta mira
        -- `mov_visibles`, no `movimientos`: tiene que coincidir con lo que el
        -- análisis va a poder usar de verdad (053/C9).
        IF NOT EXISTS (SELECT 1 FROM documentos
                       WHERE sesion_id = v_ses_id AND estado = 'parseado')
           AND NOT (v_ses_srv = 'mercado_compras'
                    AND EXISTS (SELECT 1 FROM mov_visibles
                                WHERE negocio_id = v_negocio_id
                                  AND tipo = 'compra')) THEN
            RETURN router_respuesta(v_chat_id, 'sistema.sin_documentos');
        END IF;

        UPDATE sesiones SET estado = 'procesando', paso = 'ejecutando'
        WHERE id = v_ses_id;
        INSERT INTO ejecuciones (sesion_id, negocio_id, servicio_codigo, estado)
        VALUES (v_ses_id, v_negocio_id, v_ses_srv, 'preparando')
        RETURNING id INTO v_ejec_id;

        RETURN router_respuesta(v_chat_id, 'ejecucion.en_curso', '{}'::jsonb, NULL,
                 jsonb_build_array(jsonb_build_object(
                   'tipo','ejecutar','ejecucion_id', v_ejec_id)));
    END IF;

    RETURN router_respuesta(v_chat_id, 'sistema.esperando_listo');
END;
$$;

-- =============================================================================
-- 7. El despachador
-- =============================================================================
-- Esto es todo lo que queda de las 356 líneas. Su único trabajo es el orden, y
-- el orden es el mismo de siempre. Una fase que agregue un estado agrega acá
-- tres líneas y un handler nuevo; una que cambie una conversación existente
-- reemplaza SU handler y no toca este archivo ni los otros tres.
CREATE OR REPLACE FUNCTION router_procesar_mensaje(p_evento jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_ctx    jsonb := router_ctx(p_evento);
    v_sesion record;
    v_r      jsonb;
BEGIN
    -- 1. Admin, antes de mirar la sesión: un /salud no debe refrescarle la
    --    actividad a una sesión que estaba por expirar.
    v_r := router_h_admin(v_ctx);
    IF v_r IS NOT NULL THEN RETURN v_r; END IF;

    -- 2. La sesión abierta, si la hay, y su marca de actividad.
    SELECT * INTO v_sesion FROM sesiones
    WHERE usuario_id = (v_ctx ->> 'usuario_id')::bigint AND cerrada_en IS NULL
    ORDER BY id DESC LIMIT 1;
    IF v_sesion.id IS NOT NULL THEN
        UPDATE sesiones SET ultima_actividad = now() WHERE id = v_sesion.id;
    END IF;
    v_ctx := v_ctx || jsonb_build_object(
        'sesion_id',       v_sesion.id,
        'sesion_estado',   v_sesion.estado::text,
        'sesion_paso',     v_sesion.paso,
        'sesion_servicio', v_sesion.servicio_codigo);

    -- 3. Lo que se contesta sin importar en qué paso va la conversación.
    v_r := router_h_comandos(v_ctx);
    IF v_r IS NOT NULL THEN RETURN v_r; END IF;

    -- 4. Y si no, manda el estado de la sesión.
    IF v_sesion.id IS NULL THEN
        RETURN router_h_sin_sesion(v_ctx);
    END IF;

    -- Ya se está ejecutando: nada de disparar una segunda corrida.
    IF v_sesion.estado = 'procesando' THEN
        RETURN router_respuesta((v_ctx ->> 'chat_id')::bigint, 'ejecucion.ya_en_curso');
    END IF;

    IF v_sesion.estado = 'intake' THEN
        v_r := router_h_intake(v_ctx);
        IF v_r IS NOT NULL THEN RETURN v_r; END IF;
    END IF;

    IF v_sesion.estado = 'recibiendo' THEN
        RETURN router_h_recibiendo(v_ctx);
    END IF;

    RETURN router_respuesta((v_ctx ->> 'chat_id')::bigint, 'sistema.no_entendido');
END;
$$;
