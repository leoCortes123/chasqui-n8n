-- 046_conversacion_directa.sql — la entrada se simplifica y la carga de
-- archivos deja de dar por sentado de dónde salen.
--
-- Seis cambios, todos de conversación:
--
-- 1. Se va el teclado fijo (reply keyboard) que había puesto la 045. Satura la
--    vista y, en el plan gratuito, la interacción es solo por chat: el portal es
--    para después. Se borran la tabla, las funciones y la columna: dejar la
--    maquinaria apagada es peor que no tenerla.
-- 2. La bienvenida vuelve a ser UN mensaje —el "¿Por dónde empezamos?" aparte
--    no aportaba nada—, y ya no anuncia servicios: se presenta como asistente,
--    invita a escribir lo que el usuario tenga en mente y ofrece un único
--    botón, "¿Qué puedo hacer?".
-- 3. Ese botón abre el menú de servicios (el módulo de la 045, renombrado).
-- 4. Antes de pedir archivos se pregunta la NATURALEZA del negocio
--    (minimercado, distribuidora, …) y se guarda en `negocios.tipo`: los mismos
--    números se leen distinto según el tipo de negocio, y sin eso el análisis
--    compara contra un promedio que no existe.
-- 5. El mensaje que pide archivos deja de nombrar la DIAN y "tu sistema" —de
--    dónde salgan es irrelevante—, aclara que son facturas de ventas y compras,
--    y recomienda cuánta historia mandar. Solo lleva botón de Cancelar: el de
--    analizar aparece cuando ya hay algo cargado.
-- 6. El resumen "esto fue lo que cargué" dice el periodo de facturación que
--    cubren los archivos.

-- =============================================================================
-- 1. Fuera el teclado fijo
-- =============================================================================
DROP FUNCTION IF EXISTS teclado_fijo_botones();
DROP FUNCTION IF EXISTS atajo_comando(text);
DROP TABLE IF EXISTS atajos_teclado;
ALTER TABLE plantillas DROP COLUMN IF EXISTS teclado_fijo;

-- resolver_plantilla vuelve a la forma de la 023 (sin la clave `fijo`).
CREATE OR REPLACE FUNCTION resolver_plantilla(p_clave text,
                                              p_vars jsonb DEFAULT '{}'::jsonb,
                                              p_teclado jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cuerpo  text;
    v_formato text;
    v_crudas  jsonb;
    v_teclado jsonb;
    v_vars    jsonb;
    k text; val text;
BEGIN
    v_vars := CASE WHEN jsonb_typeof(p_vars) = 'object' THEN p_vars ELSE '{}'::jsonb END;

    SELECT cuerpo, formato, crudas, teclado
      INTO v_cuerpo, v_formato, v_crudas, v_teclado
    FROM plantillas WHERE clave = p_clave AND activo LIMIT 1;

    IF v_cuerpo IS NULL THEN
        -- Sin plantilla se manda la clave como texto. Eso es contenido
        -- arbitrario (así entregan su salida los comandos de admin), así que
        -- acá SÍ se escapa.
        v_cuerpo  := esc_html(p_clave);
        v_formato := 'html';
        v_crudas  := '[]'::jsonb;
        v_teclado := '[]'::jsonb;
    END IF;

    FOR k, val IN SELECT * FROM jsonb_each_text(v_vars) LOOP
        v_cuerpo := replace(v_cuerpo, '{{' || k || '}}',
            CASE WHEN v_crudas ? k THEN coalesce(val, '') ELSE esc_html(val) END);
    END LOOP;

    RETURN jsonb_build_object('texto', v_cuerpo, 'formato', v_formato,
             'teclado', teclado_markup(
                 CASE WHEN jsonb_typeof(coalesce(p_teclado, 'null'::jsonb)) = 'array'
                      THEN p_teclado ELSE v_teclado END, v_vars));
END;
$$;

-- =============================================================================
-- 2. La bienvenida: un mensaje, un botón
-- =============================================================================
DROP FUNCTION IF EXISTS router_bienvenida(bigint);
DELETE FROM plantillas WHERE clave = 'sistema.menu';

-- El módulo pasa a ser la respuesta a "¿qué puedo hacer?": el nombre del botón
-- ya no describe un área del negocio sino la pregunta que se está contestando.
UPDATE modulos SET
    nombre  = '🔎 ¿Qué puedo hacer?',
    titular =
'Esto es lo que puedo hacer por ahora:',
    ayuda =
'<b>Cómo funciona</b>

Me mandás las facturas de tu negocio —las de venta y las de compra— y yo las leo. No importa de dónde salgan ni cómo se llamen las columnas.

Con eso te digo qué productos te dejan plata y cuáles no, a cuáles les subió el costo, cuáles se te van a agotar y en qué conviene que gastes primero. Y no me quedo en el dato: te digo cuánto te está costando cada problema y qué podés hacer con él.

Cuanta más historia me des, mejor: con tres meses ya sale un análisis serio.'
WHERE codigo = 'negocio';

UPDATE plantillas SET cuerpo =
'¡Hola! 👋 Soy <b>Chasqui</b>, un asistente para tu negocio.

Contame qué tenés en mente y te ayudo con lo que sepa. Y si preferís, puedo revisar tus números y decirte dónde estás ganando, dónde se te está yendo la plata y qué conviene hacer esta semana.',
  formato = 'html',
  teclado = '[[{"texto":"🔎 ¿Qué puedo hacer?","dato":"mod:negocio"}]]'::jsonb,
  version = version + 1
WHERE clave = 'sistema.bienvenida';

-- =============================================================================
-- 3. Naturaleza del negocio
-- =============================================================================
-- Los mismos números se leen distinto según el negocio: un 18% de margen es
-- normal en una distribuidora y flojo en un minimercado. Se pregunta UNA vez
-- (`negocios.tipo`) y a partir de ahí viaja en los hallazgos.
CREATE TABLE IF NOT EXISTS tipos_negocio (
    codigo text PRIMARY KEY,
    nombre text NOT NULL,          -- texto del botón
    orden  int  NOT NULL DEFAULT 100,
    activo boolean NOT NULL DEFAULT true
);

INSERT INTO tipos_negocio (codigo, nombre, orden) VALUES
  ('minimercado',   '🛒 Minimercado o tienda',    10),
  ('almacen',       '🏬 Almacén o punto de venta', 20),
  ('distribuidora', '🚚 Distribuidora o mayorista', 30),
  ('restaurante',   '🍽️ Restaurante o cafetería',  40),
  ('otro',          '🏷️ Otro',                     50)
ON CONFLICT (codigo) DO UPDATE
  SET nombre = EXCLUDED.nombre, orden = EXCLUDED.orden, activo = true;

CREATE OR REPLACE FUNCTION teclado_tipos_negocio() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT coalesce(jsonb_agg(jsonb_build_array(jsonb_build_object(
             'texto', nombre, 'dato', 'tipo:' || codigo)) ORDER BY orden), '[]'::jsonb)
    FROM tipos_negocio WHERE activo;
$$;

-- =============================================================================
-- 4. Los mensajes de la carga
-- =============================================================================
INSERT INTO plantillas (clave, cuerpo, formato, variables, crudas, teclado) VALUES
('sistema.pedir_tipo',
'Antes de arrancar, contame: ¿qué tipo de negocio es?

Lo necesito para leer bien tus números —lo que en un negocio es un margen normal, en otro es una alarma—.',
 'html', '[]'::jsonb, '[]'::jsonb,
 '[]'::jsonb)
ON CONFLICT (clave) DO UPDATE
  SET cuerpo = EXCLUDED.cuerpo, formato = EXCLUDED.formato,
      variables = EXCLUDED.variables, crudas = EXCLUDED.crudas,
      activo = true, version = plantillas.version + 1;

-- El teclado lo inyecta el router (sale de `tipos_negocio`), por eso la fila va
-- sin botones.

UPDATE plantillas SET cuerpo =
'Listo: <b>{{servicio}}</b>.

Mandame los archivos de <b>facturación</b> de tu negocio: las <b>ventas</b> y las <b>compras</b>. De dónde salgan no me importa —lo que exporte tu sistema, lo que te pase el contador, un Excel que llevés a mano— y tampoco cómo se llamen las columnas: yo los leo.

📎 Me sirven Excel, CSV, XML de factura electrónica y PDF.

📅 <b>Cuánta historia mandarme:</b> con <b>3 meses</b> ya sale un análisis serio. Entre más me mandes, mejor: las tendencias de costo y lo que rota lento no se ven en dos semanas.

Empezá a mandarlos de a uno. Te voy diciendo qué leí de cada archivo, y ahí mismo te dejo el botón para analizar cuando estés listo.',
  formato = 'html',
  teclado = '[[{"texto":"✖️ Cancelar","dato":"/cancelar"}]]'::jsonb,
  version = version + 1
WHERE clave = 'sistema.pedir_archivos';

-- =============================================================================
-- 5. El resumen de la carga dice el periodo
-- =============================================================================
-- Saber CUÁNTO tiempo cubre lo cargado es lo que le permite al usuario decidir
-- si mandar más archivos antes de analizar. Es el mismo dato que después manda
-- en el encabezado del informe, dicho antes de gastar tokens.
CREATE OR REPLACE FUNCTION ingesta_resumen_sesion(p_sesion_id bigint)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    WITH docs AS (
        SELECT d.id, d.nombre_archivo,
               (SELECT count(*) FROM movimientos m WHERE m.documento_id = d.id) AS filas,
               (SELECT round(coalesce(sum(m.valor_total), 0))
                  FROM movimientos m WHERE m.documento_id = d.id)               AS total
        FROM documentos d
        WHERE d.sesion_id = p_sesion_id AND d.estado = 'parseado'
    ),
    rango AS (
        SELECT min(m.fecha) AS desde, max(m.fecha) AS hasta,
               count(*) FILTER (WHERE m.tipo = 'venta')  AS ventas,
               count(*) FILTER (WHERE m.tipo = 'compra') AS compras
        FROM movimientos m
        JOIN documentos d ON d.id = m.documento_id
        WHERE d.sesion_id = p_sesion_id AND m.fecha IS NOT NULL
    )
    SELECT jsonb_build_object(
        'archivos', (SELECT count(*) FROM docs),
        'detalle',  coalesce((SELECT string_agg(
                        format('📄 %s: %s registros, $%s',
                               nombre_archivo, filas, miles(total)),
                        E'\n' ORDER BY id) FROM docs), ''),
        'total',    '$' || miles((SELECT coalesce(sum(total), 0) FROM docs)),

        -- Periodo de facturación cubierto, y el aviso cuando es corto: es el
        -- momento de mandar más, no después de ver un informe flojo.
        'periodo', coalesce((SELECT E'\n📅 Periodo de facturación: '
                                    || periodo_es(desde, hasta)
                                    || CASE WHEN hasta - desde < 80
                                            THEN ' — es poco tiempo; si tenés más meses, mandámelos y el análisis sale mucho mejor.'
                                            ELSE '' END
                             FROM rango WHERE desde IS NOT NULL), ''),

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

UPDATE plantillas SET cuerpo =
'Esto fue lo que cargué:

{{detalle}}

Total: {{total}}{{periodo}}{{aviso_nit}}',
  variables = '["archivos","detalle","total","periodo","aviso_nit"]'::jsonb,
  version = version + 1
WHERE clave = 'ingesta.resumen_sesion';

-- =============================================================================
-- 6. Router
-- =============================================================================
-- Copia de la 045 con lo marcado ">>> 046":
--   * se va la traducción de atajos del teclado fijo;
--   * /start y /ayuda vuelven a UNA respuesta;
--   * `tipo:` guarda la naturaleza del negocio;
--   * elegir servicio pregunta el tipo antes de pedir archivos, si falta.

-- Qué contestar cuando ya hay servicio elegido: o la pregunta del tipo de
-- negocio, o el pedido de archivos. Existe para no repetirla en los tres
-- lugares donde una sesión pasa a 'recibiendo'.
CREATE OR REPLACE FUNCTION router_arranque_servicio(p_negocio_id bigint,
                                                    p_chat_id    bigint,
                                                    p_servicio   text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_nombre text;
    v_tipo   text;
BEGIN
    SELECT nombre INTO v_nombre FROM servicios WHERE codigo = p_servicio;
    SELECT nullif(btrim(coalesce(tipo, '')), '') INTO v_tipo
    FROM negocios WHERE id = p_negocio_id;

    -- Sin negocio asignado no hay dónde guardar el tipo: no se pregunta lo que
    -- no se puede responder.
    IF p_negocio_id IS NOT NULL AND v_tipo IS NULL THEN
        RETURN router_respuesta(p_chat_id, 'sistema.pedir_tipo',
                 '{}'::jsonb, teclado_tipos_negocio());
    END IF;

    IF p_servicio = 'mercado_compras' THEN
        RETURN mercado_compras_bienvenida(p_negocio_id, p_chat_id);
    END IF;

    RETURN router_respuesta(p_chat_id, 'sistema.pedir_archivos',
             jsonb_build_object('servicio', v_nombre));
END;
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
    v_tip        text;          -- >>> 046: naturaleza del negocio (tipo:<codigo>)
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
        RETURN router_respuesta(v_chat_id, 'sistema.bienvenida');   -- >>> 046
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

    -- ---- Módulos -----------------------------------------------------------
    -- Entrar a un módulo no abre sesión ni toca nada: es un menú.
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

    -- ---- >>> 046: naturaleza del negocio -----------------------------------
    -- Se contesta una vez y sigue el camino que estaba interrumpido. Un botón
    -- viejo del historial vuelve a guardar lo mismo: es idempotente.
    IF v_cmd = 'tipo' THEN
        IF v_negocio_id IS NULL
           OR NOT EXISTS (SELECT 1 FROM tipos_negocio WHERE activo AND codigo = v_tip) THEN
            RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
        END IF;
        UPDATE negocios SET tipo = v_tip WHERE id = v_negocio_id;

        IF v_sesion.id IS NOT NULL AND v_sesion.servicio_codigo IS NOT NULL THEN
            RETURN router_arranque_servicio(v_negocio_id, v_chat_id,
                                            v_sesion.servicio_codigo);
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
            RETURN router_arranque_servicio(v_negocio_id, v_chat_id, v_servicio.codigo);
        END IF;

        INSERT INTO sesiones (usuario_id, negocio_id, estado, paso)
        VALUES (v_usuario_id, v_negocio_id, 'intake', 'elegir_servicio');
        RETURN router_respuesta(v_chat_id, 'sistema.elegir_servicio',
                 '{}'::jsonb, teclado_servicios());
    END IF;

    -- ---- Servicio elegido desde el menú (045) ------------------------------
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

        RETURN router_arranque_servicio(v_negocio_id, v_chat_id, v_servicio.codigo);
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

        RETURN router_arranque_servicio(v_negocio_id, v_chat_id, v_servicio.codigo);
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

NOTIFY pgrst, 'reload schema';
