-- 045_menu_modulos.sql — la primera pantalla deja de vender un análisis y pasa
-- a presentar a Chasqui; los servicios se cuelgan de un MÓDULO.
--
-- Por qué un nivel más y no una lista más larga de servicios:
--
--   * el primer mensaje es la única oportunidad de que alguien entienda qué es
--     esto. Si arranca con "¿qué análisis necesitás?" está pidiendo una decisión
--     antes de haber explicado nada;
--   * "análisis de ventas y compras" y "mercado de compras" no son dos productos
--     distintos, son dos herramientas de lo MISMO: administrar el negocio. Ese
--     es el módulo, y es la puerta al ERP que viene después;
--   * el tope de botones (6, migración 027) se gasta rápido si todo cuelga de la
--     raíz. Con módulos, cada nivel tiene pocas opciones y ninguna se pierde.
--
-- Estructura de la conversación desde /start:
--
--   sistema.bienvenida   texto comercial, SIN servicios, con TECLADO FIJO
--   sistema.menu         "¿por dónde empezamos?" + un botón por módulo
--     mod:negocio  -> sistema.modulo        (titular del módulo + sus servicios)
--       svc:<cod>  -> sistema.pedir_archivos (o la bienvenida del servicio)
--       modayuda:negocio -> sistema.modulo_ayuda
--
-- Agregar un módulo sigue siendo un INSERT; mover un servicio de módulo, un
-- UPDATE. Ningún nodo de n8n sabe que los módulos existen.
--
-- SON DOS MENSAJES, no uno, por una restricción de Telegram: un mensaje lleva UN
-- reply_markup. O botones inline, o teclado fijo. La bienvenida se queda con el
-- teclado fijo (que es lo que hay que armar una sola vez y dura para siempre) y
-- el menú con los inline. En el chat se leen como un saludo y su menú.

-- =============================================================================
-- 1. Módulos
-- =============================================================================
-- `titular` y `ayuda` son texto de mensaje, no metadatos: viven acá y no en
-- `plantillas` porque son POR MÓDULO. La plantilla es una sola con {{titular}};
-- si vivieran en plantillas haría falta una fila por módulo y el INSERT de un
-- módulo dejaría de ser un INSERT.
CREATE TABLE IF NOT EXISTS modulos (
    codigo      text PRIMARY KEY,
    nombre      text NOT NULL,              -- texto del botón
    titular     text NOT NULL,              -- mensaje al entrar (HTML)
    ayuda       text NOT NULL,              -- "qué hace este módulo" (HTML)
    orden       int  NOT NULL DEFAULT 100,
    activo      boolean NOT NULL DEFAULT true
);

COMMENT ON TABLE modulos IS
  'Agrupador de servicios para el menú del chat. Un módulo = un botón en la '
  'bienvenida; sus servicios activos son los botones del segundo nivel.';

INSERT INTO modulos (codigo, nombre, titular, ayuda, orden) VALUES
('negocio', '📊 Administración de mi negocio',
'<b>Administración de mi negocio</b>

Acá convierto tus facturas y tus ventas en decisiones concretas: qué te deja plata, qué te la está costando y qué conviene hacer esta semana.

¿Con qué querés empezar?',
'<b>Cómo funciona este módulo</b>

Vos me mandás los archivos que ya tenés —las facturas XML de la DIAN, o el archivo de ventas que exporte tu sistema (Excel, CSV, lo que sea)—. No importa cómo se llamen las columnas: yo las reconozco.

Con eso te devuelvo un informe corto y en español: márgenes por producto, costos que subieron, plata concentrada en pocos proveedores y qué te conviene revisar primero.

Todo queda guardado en tu portal, así que el próximo análisis ya arranca con historia.', 10)
ON CONFLICT (codigo) DO UPDATE
  SET nombre = EXCLUDED.nombre, titular = EXCLUDED.titular,
      ayuda = EXCLUDED.ayuda, orden = EXCLUDED.orden, activo = true;

-- El servicio dice a qué módulo pertenece. NULL = no se ofrece en el menú
-- (los de entrada 'texto', como `consulta`, no se eligen: se escriben).
ALTER TABLE servicios
    ADD COLUMN IF NOT EXISTS modulo_codigo text REFERENCES modulos(codigo);

UPDATE servicios SET modulo_codigo = 'negocio'
WHERE entrada = 'archivos' AND modulo_codigo IS NULL;

-- =============================================================================
-- 2. Teclados de los dos niveles
-- =============================================================================
CREATE OR REPLACE FUNCTION teclado_modulos() RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT coalesce(
             (SELECT jsonb_agg(jsonb_build_array(jsonb_build_object(
                       'texto', nombre, 'dato', 'mod:' || codigo)) ORDER BY orden)
                FROM modulos WHERE activo),
             '[]'::jsonb)
           || jsonb_build_array(jsonb_build_array(jsonb_build_object(
                'texto', '❓ Cómo funciona Chasqui', 'dato', '/comofunciona')));
$$;

-- Los servicios de un módulo, más su ayuda y la vuelta atrás. La vuelta es
-- /ayuda —el mismo comando que el atajo del teclado fijo— para que no haya dos
-- formas de llegar al inicio.
CREATE OR REPLACE FUNCTION teclado_modulo(p_codigo text)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT coalesce(
             (SELECT jsonb_agg(jsonb_build_array(jsonb_build_object(
                       'texto', nombre, 'dato', 'svc:' || codigo)) ORDER BY orden)
                FROM servicios
               WHERE activo AND entrada = 'archivos' AND modulo_codigo = p_codigo),
             '[]'::jsonb)
           || jsonb_build_array(
                jsonb_build_array(jsonb_build_object(
                  'texto', '❓ Cómo funciona', 'dato', 'modayuda:' || p_codigo)),
                jsonb_build_array(jsonb_build_object(
                  'texto', '⬅️ Volver', 'dato', '/ayuda')));
$$;

-- =============================================================================
-- 3. Teclado fijo (reply keyboard) y sus atajos
-- =============================================================================
-- El teclado inline vive dentro de un mensaje: si la conversación avanza, queda
-- arriba y el usuario se queda sin botones a la vista. El teclado fijo reemplaza
-- al teclado del teléfono y no se va nunca, así que SIEMPRE hay algo que tocar.
--
-- Telegram lo manda como un mensaje de texto normal con el texto del botón. Por
-- eso hace falta la tabla: el router traduce ese texto al comando ANTES de
-- interpretar nada, y así un atajo no es un camino nuevo sino el mismo comando
-- de siempre. Renombrar un atajo es un UPDATE.
CREATE TABLE IF NOT EXISTS atajos_teclado (
    texto   text PRIMARY KEY,
    comando text NOT NULL,
    orden   int  NOT NULL DEFAULT 100,
    activo  boolean NOT NULL DEFAULT true
);

INSERT INTO atajos_teclado (texto, comando, orden) VALUES
  ('📊 Nuevo análisis', '/nueva',  10),
  ('🌐 Mi portal',      '/portal', 20),
  ('❓ Ayuda',          '/ayuda',  30)
ON CONFLICT (texto) DO UPDATE
  SET comando = EXCLUDED.comando, orden = EXCLUDED.orden, activo = true;

CREATE OR REPLACE FUNCTION atajo_comando(p_texto text)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT comando FROM atajos_teclado
     WHERE activo AND texto = btrim(coalesce(p_texto, '')) LIMIT 1;
$$;

-- La FORMA del teclado fijo (3 filas de 1 botón) está literal en wf_enviar, por
-- la misma limitación del nodo de Telegram que documenta gen_wf_enviar.py: solo
-- las hojas pueden salir de una expresión. Así que acá se garantiza que siempre
-- haya exactamente 3 textos; con otra cantidad, el nodo mandaría un botón con
-- texto vacío y Telegram rechazaría el mensaje ENTERO con 400.
--
-- Cambiar el número de atajos = cambiar ATAJOS_FIJOS acá y en gen_wf_enviar.py,
-- y regenerar. Es el mismo contrato que teclado_max_filas con MAX_FILAS.
CREATE OR REPLACE FUNCTION teclado_fijo_botones() RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_defecto jsonb := '["📊 Nuevo análisis","🌐 Mi portal","❓ Ayuda"]'::jsonb;
    v_out     jsonb;
BEGIN
    SELECT jsonb_agg(texto ORDER BY orden) INTO v_out
    FROM atajos_teclado WHERE activo;

    IF v_out IS NULL OR jsonb_array_length(v_out) <> 3 THEN
        RAISE WARNING 'teclado_fijo_botones: hay % atajos activos y wf_enviar '
                      'espera 3; se usan los de defecto',
                      coalesce(jsonb_array_length(v_out), 0);
        RETURN v_defecto;
    END IF;
    RETURN v_out;
END;
$$;

-- La plantilla decide si su mensaje arma el teclado fijo. Basta con marcarlo en
-- las que abren conversación: el teclado es persistente, mandarlo en cada
-- mensaje sería repetir trabajo.
ALTER TABLE plantillas
    ADD COLUMN IF NOT EXISTS teclado_fijo boolean NOT NULL DEFAULT false;

-- =============================================================================
-- 4. resolver_plantilla v4: también dice si el mensaje lleva teclado fijo
-- =============================================================================
-- Idéntica a la de 023 salvo la lectura de `teclado_fijo` y la clave `fijo` del
-- resultado. `fijo` es el ARRAY de textos, no un booleano: wf_enviar no tiene
-- por qué volver a consultar la base para saber qué dicen los botones.
CREATE OR REPLACE FUNCTION resolver_plantilla(p_clave text,
                                              p_vars jsonb DEFAULT '{}'::jsonb,
                                              p_teclado jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cuerpo  text;
    v_formato text;
    v_crudas  jsonb;
    v_teclado jsonb;
    v_fijo    boolean;
    v_vars    jsonb;
    k text; val text;
BEGIN
    v_vars := CASE WHEN jsonb_typeof(p_vars) = 'object' THEN p_vars ELSE '{}'::jsonb END;

    SELECT cuerpo, formato, crudas, teclado, teclado_fijo
      INTO v_cuerpo, v_formato, v_crudas, v_teclado, v_fijo
    FROM plantillas WHERE clave = p_clave AND activo LIMIT 1;

    IF v_cuerpo IS NULL THEN
        v_cuerpo  := esc_html(p_clave);
        v_formato := 'html';
        v_crudas  := '[]'::jsonb;
        v_teclado := '[]'::jsonb;
        v_fijo    := false;
    END IF;

    FOR k, val IN SELECT * FROM jsonb_each_text(v_vars) LOOP
        v_cuerpo := replace(v_cuerpo, '{{' || k || '}}',
            CASE WHEN v_crudas ? k THEN coalesce(val, '') ELSE esc_html(val) END);
    END LOOP;

    RETURN jsonb_build_object('texto', v_cuerpo, 'formato', v_formato,
             'teclado', teclado_markup(
                 CASE WHEN jsonb_typeof(coalesce(p_teclado, 'null'::jsonb)) = 'array'
                      THEN p_teclado ELSE v_teclado END, v_vars),
             -- null cuando no lleva: wf_enviar bifurca con !!$json.fijo.
             'fijo', CASE WHEN v_fijo THEN teclado_fijo_botones() END);
END;
$$;

-- =============================================================================
-- 5. Las plantillas de la entrada
-- =============================================================================
-- La bienvenida deja de pedir una decisión y deja de nombrar un servicio. Es
-- texto comercial: qué es Chasqui y para qué le sirve a quien lo lee. Los
-- botones están en el mensaje siguiente.
UPDATE plantillas SET cuerpo =
'¡Hola! 👋 Soy <b>Chasqui</b>.

Trabajo con vos en la administración de tu negocio: leo lo que ya tenés —tus facturas, tus ventas— y te lo devuelvo convertido en algo que se puede usar. Sin planillas, sin instalar nada, sin aprender un sistema nuevo.

Nada de informes de 40 páginas: te digo en dos minutos dónde estás ganando, dónde se te está yendo la plata y qué conviene hacer esta semana.

Empecemos 👇',
  formato = 'html',
  teclado = '[]'::jsonb,
  teclado_fijo = true,
  version = version + 1
WHERE clave = 'sistema.bienvenida';

INSERT INTO plantillas (clave, cuerpo, formato, variables, crudas, teclado) VALUES
('sistema.menu',
 '¿Por dónde empezamos?',
 'html', '[]'::jsonb, '[]'::jsonb, '[]'::jsonb),

-- El teclado de estas dos lo inyecta el router (depende del módulo), por eso la
-- fila va sin botones. `titular`/`ayuda` son HTML nuestro, de la tabla modulos:
-- van en `crudas` para que no se escapen las etiquetas.
('sistema.modulo',
 '{{titular}}',
 'html', '["titular"]'::jsonb, '["titular"]'::jsonb, '[]'::jsonb),

('sistema.modulo_ayuda',
 '{{ayuda}}',
 'html', '["ayuda"]'::jsonb, '["ayuda"]'::jsonb, '[]'::jsonb)

ON CONFLICT (clave) DO UPDATE
  SET cuerpo = EXCLUDED.cuerpo, formato = EXCLUDED.formato,
      variables = EXCLUDED.variables, crudas = EXCLUDED.crudas,
      teclado = EXCLUDED.teclado, activo = true,
      version = plantillas.version + 1;

-- Los callejones sin salida vuelven al menú de módulos, no a "/nueva": desde el
-- inicio ya no se elige un análisis, se elige un módulo.
UPDATE plantillas
SET teclado = '[[{"texto":"⬅️ Volver al inicio","dato":"/ayuda"}]]'::jsonb,
    version = version + 1
WHERE clave IN ('sistema.como_funciona', 'sistema.privacidad');

-- =============================================================================
-- 6. Router
-- =============================================================================
-- Copia de la 043 con lo marcado ">>> 045":
--   * el texto de un atajo del teclado fijo se traduce a su comando;
--   * /start y /ayuda devuelven DOS mensajes (bienvenida + menú de módulos);
--   * `mod:` y `modayuda:` son dos comandos nuevos;
--   * `svc:` abre sesión aunque no hubiera ninguna: ahora se puede tocar un
--     servicio desde el menú sin pasar por /nueva.

-- >>> 045: la bienvenida son dos respuestas, así que no cabe en
-- router_respuesta (que arma una sola). Vive acá para no repetir el jsonb en
-- los cuatro lugares que saludan.
CREATE OR REPLACE FUNCTION router_bienvenida(p_chat bigint)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
      'chat_id', p_chat,
      'respuestas', jsonb_build_array(
        jsonb_build_object('plantilla', 'sistema.bienvenida', 'vars', '{}'::jsonb),
        jsonb_build_object('plantilla', 'sistema.menu', 'vars', '{}'::jsonb,
                           'teclado', teclado_modulos())),
      'acciones', '[]'::jsonb);
$$;

CREATE OR REPLACE FUNCTION router_procesar_mensaje(p_evento jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_usuario_id bigint;
    v_chat_id    bigint  := (p_evento #>> '{chat,id}')::bigint;
    v_texto      text    := btrim(coalesce(p_evento ->> 'texto', ''));
    v_cmd        text;
    v_svc        text;          -- código que llegó por botón (svc:<codigo>)
    v_mod        text;          -- código de módulo (mod:/modayuda:)
    v_arg        text;          -- resto del mensaje después del comando
    v_tiene_doc  boolean := coalesce((p_evento ->> 'tiene_documento')::boolean, false);
    v_sesion     record;
    v_negocio_id bigint;
    v_autoriz    boolean;
    v_rol        rol_usuario;
    v_servicio   record;
    v_modulo     record;
    v_n_serv     int;
    v_consulta   boolean;
    v_ejec_id    bigint;
    v_nueva_ses  bigint;
    v_titulo     text;
BEGIN
    -- >>> 045: el teclado fijo manda el TEXTO del botón como mensaje normal.
    -- Traducirlo acá, antes de partir el comando, hace que un atajo y su
    -- comando escrito sean literalmente la misma ejecución.
    v_texto := coalesce(atajo_comando(v_texto), v_texto);

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
        RETURN router_bienvenida(v_chat_id);         -- >>> 045
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
            RETURN router_bienvenida(v_chat_id);     -- >>> 045
        END IF;
        RETURN router_respuesta(v_chat_id, 'sistema.no_autorizado');
    END IF;

    -- ---- >>> 045: módulos --------------------------------------------------
    -- Entrar a un módulo no abre sesión ni toca nada: es un menú. La sesión
    -- empieza recién cuando se elige un servicio.
    IF v_cmd = 'mod' THEN
        SELECT * INTO v_modulo FROM modulos WHERE activo AND codigo = v_mod;
        IF v_modulo.codigo IS NULL THEN
            RETURN router_bienvenida(v_chat_id);
        END IF;
        RETURN router_respuesta(v_chat_id, 'sistema.modulo',
                 jsonb_build_object('titular', v_modulo.titular),
                 teclado_modulo(v_modulo.codigo));
    END IF;

    IF v_cmd = 'modayuda' THEN
        SELECT * INTO v_modulo FROM modulos WHERE activo AND codigo = v_mod;
        IF v_modulo.codigo IS NULL THEN
            RETURN router_bienvenida(v_chat_id);
        END IF;
        RETURN router_respuesta(v_chat_id, 'sistema.modulo_ayuda',
                 jsonb_build_object('ayuda', v_modulo.ayuda),
                 teclado_modulo(v_modulo.codigo));
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

    -- ---- >>> 045: servicio elegido desde el menú del módulo ----------------
    -- Antes un `svc:` sin sesión abierta caía en "no tenés un análisis en
    -- curso": el botón solo servía dentro del intake. Ahora el menú del módulo
    -- es una entrada legítima, así que abre la sesión él mismo. Con la sesión ya
    -- en 'recibiendo' no se toca: ahí un `svc:` es un botón viejo del historial
    -- y lo sigue atendiendo el bloque de más abajo.
    IF v_cmd = 'svc' AND (v_sesion.id IS NULL OR v_sesion.estado = 'intake') THEN
        SELECT * INTO v_servicio FROM servicios
        WHERE activo AND entrada = 'archivos' AND codigo = v_svc;

        IF v_servicio.codigo IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.servicio_no_reconocido',
                     '{}'::jsonb, teclado_servicios());
        END IF;

        IF v_sesion.id IS NULL THEN
            INSERT INTO sesiones (usuario_id, negocio_id, servicio_codigo, estado, paso)
            VALUES (v_usuario_id, v_negocio_id, v_servicio.codigo,
                    'recibiendo', 'cargar_archivos');
        ELSE
            UPDATE sesiones SET servicio_codigo = v_servicio.codigo,
                   estado = 'recibiendo', paso = 'cargar_archivos'
            WHERE id = v_sesion.id;
        END IF;

        IF v_servicio.codigo = 'mercado_compras' THEN
            RETURN mercado_compras_bienvenida(v_negocio_id, v_chat_id);
        END IF;
        RETURN router_respuesta(v_chat_id, 'sistema.pedir_archivos',
                 jsonb_build_object('servicio', v_servicio.nombre));
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
    -- Queda para el nombre escrito a mano y para el archivo mandado antes de
    -- elegir; el botón `svc:` ya lo resolvió el bloque de arriba.
    IF v_sesion.estado = 'intake' AND v_sesion.paso = 'elegir_servicio' THEN
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
               paso = 'cargar_archivos' WHERE id = v_sesion.id;

        IF v_tiene_doc THEN
            RETURN router_respuesta(v_chat_id, NULL, NULL, NULL,
                     jsonb_build_array(jsonb_build_object(
                       'tipo','ingerir','sesion_id', v_sesion.id)));
        END IF;

        IF v_servicio.codigo = 'mercado_compras' THEN
            RETURN mercado_compras_bienvenida(v_negocio_id, v_chat_id);
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

        -- La pregunta "¿son todos?" se contesta acá (042).
        IF v_cmd = '/todos' THEN
            IF NOT EXISTS (SELECT 1 FROM documentos
                           WHERE sesion_id = v_sesion.id AND estado = 'parseado') THEN
                RETURN router_respuesta(v_chat_id, 'sistema.sin_documentos');
            END IF;
            RETURN router_respuesta(v_chat_id, 'ingesta.resumen_sesion',
                     ingesta_resumen_sesion(v_sesion.id));
        END IF;
        IF v_cmd = '/faltan' THEN
            RETURN router_respuesta(v_chat_id, 'ingesta.esperando_mas');
        END IF;

        IF v_cmd IN ('/listo','/analizar','/fin') THEN
            -- mercado_compras puede correr sin archivos en la sesión si el
            -- negocio ya tiene compras cargadas de antes (043).
            IF NOT EXISTS (SELECT 1 FROM documentos
                           WHERE sesion_id = v_sesion.id AND estado = 'parseado')
               AND NOT (v_sesion.servicio_codigo = 'mercado_compras'
                        AND EXISTS (SELECT 1 FROM movimientos
                                    WHERE negocio_id = v_negocio_id
                                      AND tipo = 'compra')) THEN
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

-- Tabla y funciones nuevas: PostgREST cachea el esquema y no las vería hasta
-- reiniciar. Ninguna es pública (la 039 dejó el default global sin EXECUTE para
-- PUBLIC), pero el cache igual hay que refrescarlo.
NOTIFY pgrst, 'reload schema';
