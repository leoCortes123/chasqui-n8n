-- 033_portal.sql — la puerta del portal: enlace mágico, JWT y las RPC que el
-- navegador puede llamar.
--
-- Contexto: no hay API propia. PostgREST expone esta base por HTTP y el portal
-- es HTML plano que llama funciones. Todo lo que sigue existe para que eso sea
-- seguro sin escribir un backend.
--
-- === El modelo de seguridad, en cuatro reglas =================================
--
-- 1. El navegador NO tiene permisos sobre ninguna tabla. Cero GRANTs sobre
--    tablas o vistas. Lo único que puede hacer es ejecutar las funciones
--    `portal_*`. Si mañana aparece una tabla nueva, queda inaccesible sola: hay
--    que otorgarla a propósito. Esto es lo que hace innecesario el RLS que el
--    plan descartó —no hay consulta libre que filtrar—.
--
-- 2. El `negocio_id` NUNCA viaja como parámetro. Sale del JWT, dentro de cada
--    función. Un usuario no puede pedir los datos de otro negocio porque no
--    tiene dónde escribir el número.
--
-- 3. La identidad es Telegram. `/portal` manda un enlace con un token de un
--    solo uso y 15 minutos de vida; el token se cambia por un JWT de 12 horas.
--    No hay contraseñas que recuperar ni invitaciones que administrar.
--
-- 4. El secreto de firma no vive en la base: PostgREST lo inyecta como GUC
--    (`app.settings.jwt_secret`, desde PGRST_APP_SETTINGS_JWT_SECRET). Un
--    volcado de la base no alcanza para falsificar sesiones.
--
-- Los roles (`authenticator`, `portal_anon`, `portal_usuario`) los crea
-- bin/preparar-portal.sh, que corre como superusuario: CREATE ROLE no está al
-- alcance del dueño de la base. Esta migración da por hecho que existen.

-- =============================================================================
-- 1. Tokens de un solo uso
-- =============================================================================

CREATE TABLE IF NOT EXISTS portal_tokens (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    usuario_id bigint NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    -- Se guarda el sha256, no el token: si alguien lee la tabla, no puede
    -- entrar con lo que encuentre.
    hash       bytea NOT NULL UNIQUE,
    expira_en  timestamptz NOT NULL,
    usado_en   timestamptz,
    creado_en  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_portal_tokens_vivos ON portal_tokens(expira_en)
    WHERE usado_en IS NULL;

-- Lo llama el router, con la conexión de n8n. Devuelve el token en claro una
-- sola vez: después ya no se puede reconstruir.
CREATE OR REPLACE FUNCTION portal_token_crear(p_usuario_id bigint,
                                              p_minutos int DEFAULT 15)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_token text := encode(gen_random_bytes(24), 'hex');
BEGIN
    -- Un enlace nuevo invalida los anteriores del mismo usuario: si alguien
    -- pidió dos, el viejo deja de servir.
    UPDATE portal_tokens SET usado_en = now()
    WHERE usuario_id = p_usuario_id AND usado_en IS NULL;

    INSERT INTO portal_tokens (usuario_id, hash, expira_en)
    VALUES (p_usuario_id, digest(v_token, 'sha256'),
            now() + make_interval(mins => greatest(p_minutos, 1)));

    RETURN v_token;
END;
$$;

-- =============================================================================
-- 2. Firma de JWT en SQL
-- =============================================================================

-- base64url: sin relleno, sin saltos de línea (encode() los mete cada 76
-- caracteres y romperían el token).
CREATE OR REPLACE FUNCTION b64url(p bytea) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT rtrim(translate(replace(encode(p, 'base64'), E'\n', ''), '+/', '-_'), '=');
$$;

CREATE OR REPLACE FUNCTION jwt_firmar(p_payload jsonb, p_secreto text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT cuerpo || '.' || b64url(hmac(cuerpo, p_secreto, 'sha256'))
    FROM (SELECT b64url(convert_to('{"alg":"HS256","typ":"JWT"}', 'utf8')) || '.' ||
                 b64url(convert_to(p_payload::text, 'utf8')) AS cuerpo) s;
$$;

-- =============================================================================
-- 3. Abrir sesión: token de un uso -> JWT
-- =============================================================================
-- Es la ÚNICA función que puede llamar un visitante sin sesión.

CREATE OR REPLACE FUNCTION portal_sesion_abrir(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE
    v_horas    int := 12;
    v_secreto  text := current_setting('app.settings.jwt_secret', true);
    v_usuario  bigint;
    v_negocio  bigint;
    v_exp      bigint;
BEGIN
    IF coalesce(v_secreto, '') = '' THEN
        RAISE EXCEPTION 'portal sin secreto de firma configurado';
    END IF;

    UPDATE portal_tokens SET usado_en = now()
    WHERE hash = digest(coalesce(p_token, ''), 'sha256')
      AND usado_en IS NULL
      AND expira_en > now()
    RETURNING usuario_id INTO v_usuario;

    IF v_usuario IS NULL THEN
        -- Un solo mensaje para "no existe", "ya se usó" y "venció": no hay nada
        -- que ganar contándole al que prueba tokens cuál de las tres fue.
        RETURN jsonb_build_object('ok', false, 'error', 'enlace_invalido');
    END IF;

    SELECT negocio_id INTO v_negocio FROM usuarios WHERE id = v_usuario;
    v_exp := extract(epoch FROM now() + make_interval(hours => v_horas))::bigint;

    RETURN jsonb_build_object(
        'ok', true,
        'expira', v_exp,
        'jwt', jwt_firmar(jsonb_build_object(
                 'role', 'portal_usuario',
                 'usuario_id', v_usuario,
                 'negocio_id', v_negocio,
                 'exp', v_exp), v_secreto));
END;
$$;

-- =============================================================================
-- 4. Quién es el que llama
-- =============================================================================
-- Los claims los pone PostgREST tras verificar la firma. Si no hay claims, no
-- hay usuario: las funciones de abajo abortan y no devuelven nada de nadie.

CREATE OR REPLACE FUNCTION portal_claim(p_clave text)
RETURNS bigint LANGUAGE sql STABLE AS $$
    SELECT nullif(current_setting('request.jwt.claims', true)::jsonb ->> p_clave, '')::bigint;
$$;

CREATE OR REPLACE FUNCTION portal_negocio() RETURNS bigint
LANGUAGE plpgsql STABLE AS $$
DECLARE v_id bigint := portal_claim('negocio_id');
BEGIN
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'sesión sin negocio' USING ERRCODE = '42501';
    END IF;
    RETURN v_id;
END;
$$;

-- =============================================================================
-- 5. Las RPC del portal
-- =============================================================================
-- Todas SECURITY DEFINER (corren con los permisos del dueño, que sí puede leer
-- las tablas) y todas filtran por portal_negocio(). Devuelven jsonb porque
-- quien las consume es fetch() desde HTML plano.

CREATE OR REPLACE FUNCTION portal_perfil()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE
    v_negocio bigint := portal_negocio();
    v_usuario bigint := portal_claim('usuario_id');
BEGIN
    RETURN jsonb_build_object(
      'negocio', (SELECT jsonb_build_object('id', n.id, 'nombre', n.nombre,
                    'nit', n.nit, 'tipo', n.tipo, 'plan', n.plan)
                  FROM negocios n WHERE n.id = v_negocio),
      'usuario', (SELECT jsonb_build_object('id', u.id, 'nombre', u.nombre,
                    'rol', u.rol, 'telegram', u.telegram_username)
                  FROM usuarios u WHERE u.id = v_usuario),
      'consumo', (SELECT jsonb_build_object('tokens_mes', c.tokens_mes,
                    'cupo', c.cupo_tokens_mes, 'ejecuciones_mes', c.ejecuciones_mes)
                  FROM v_consumo_negocio c WHERE c.negocio_id = v_negocio),
      'cobertura', (SELECT jsonb_build_object('hechos', c.hechos, 'precios', c.precios,
                      'pendientes', c.pendientes, 'ultimo_cambio', c.ultimo_cambio)
                    FROM v_conocimiento_cobertura c WHERE c.negocio_id = v_negocio));
END;
$$;

CREATE OR REPLACE FUNCTION portal_conocimiento(p_tipo text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    RETURN coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', c.id, 'tipo', c.tipo, 'clave', c.clave, 'titulo', c.titulo,
               'contenido', c.contenido, 'datos', c.datos, 'origen', c.origen,
               'vigente_hasta', c.vigente_hasta,
               'actualizado_en', c.actualizado_en)
             ORDER BY c.tipo, c.titulo)
      FROM conocimiento c
      WHERE c.negocio_id = v_negocio
        AND (p_tipo IS NULL OR c.tipo = p_tipo)), '[]'::jsonb);
END;
$$;

-- Alta y edición en una sola puerta. Con p_id edita; sin p_id crea (y si trae
-- clave, pisa el hecho que tenga esa clave: es lo que permite reimportar una
-- lista de precios sin duplicar).
CREATE OR REPLACE FUNCTION portal_conocimiento_guardar(
    p_titulo       text,
    p_tipo         text DEFAULT 'faq',
    p_contenido    text DEFAULT NULL,
    p_clave        text DEFAULT NULL,
    p_datos        jsonb DEFAULT '{}'::jsonb,
    p_id           bigint DEFAULT NULL,
    p_pendiente_id bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE
    v_negocio bigint := portal_negocio();
    v_usuario bigint := portal_claim('usuario_id');
    v_id      bigint;
BEGIN
    IF coalesce(btrim(p_titulo), '') = '' THEN
        RAISE EXCEPTION 'el título es obligatorio' USING ERRCODE = '22023';
    END IF;

    IF p_id IS NOT NULL THEN
        UPDATE conocimiento SET
            tipo = p_tipo, titulo = btrim(p_titulo), contenido = p_contenido,
            clave = p_clave, datos = coalesce(p_datos, '{}'::jsonb),
            actualizado_en = now(), actualizado_por = v_usuario
        WHERE id = p_id AND negocio_id = v_negocio   -- el negocio, siempre
        RETURNING id INTO v_id;

        IF v_id IS NULL THEN
            RAISE EXCEPTION 'no existe ese hecho' USING ERRCODE = '42501';
        END IF;
    ELSE
        v_id := conocimiento_guardar(v_negocio, p_tipo, btrim(p_titulo), p_contenido,
                                     p_clave, coalesce(p_datos, '{}'::jsonb),
                                     'portal', v_usuario, NULL);
    END IF;

    -- Marcar una pendiente como resuelta es explícito, nunca por parecido.
    IF p_pendiente_id IS NOT NULL THEN
        UPDATE conocimiento_pendiente SET resuelto_por = v_id
        WHERE id = p_pendiente_id AND negocio_id = v_negocio;
    END IF;

    RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$$;

CREATE OR REPLACE FUNCTION portal_conocimiento_borrar(p_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE
    v_negocio bigint := portal_negocio();
    v_n       int;
BEGIN
    -- Las pendientes que este hecho resolvía vuelven a la lista: si se borra la
    -- respuesta, la pregunta sigue sin contestar.
    UPDATE conocimiento_pendiente SET resuelto_por = NULL
    WHERE resuelto_por = p_id AND negocio_id = v_negocio;

    DELETE FROM conocimiento WHERE id = p_id AND negocio_id = v_negocio;
    GET DIAGNOSTICS v_n = ROW_COUNT;

    RETURN jsonb_build_object('ok', v_n > 0);
END;
$$;

CREATE OR REPLACE FUNCTION portal_pendientes()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    RETURN coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', f.id, 'pregunta', f.pregunta, 'veces', f.veces,
               'ultima_en', f.ultima_en,
               'candidato_id', f.candidato_id, 'candidato', f.candidato)
             ORDER BY f.veces DESC, f.ultima_en DESC)
      FROM v_conocimiento_faltante f WHERE f.negocio_id = v_negocio), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION portal_informes(p_limite int DEFAULT 20)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    RETURN coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', e.id, 'servicio', s.nombre, 'servicio_codigo', e.servicio_codigo,
               'fecha', e.inicio, 'estado', e.estado,
               'resumen', left(regexp_replace(coalesce(e.texto, ''), '<[^>]+>', '', 'g'), 160))
             ORDER BY e.inicio DESC)
      FROM (SELECT * FROM ejecuciones
             WHERE negocio_id = v_negocio AND estado = 'completada'
             ORDER BY inicio DESC LIMIT greatest(coalesce(p_limite, 20), 1)) e
      LEFT JOIN servicios s ON s.codigo = e.servicio_codigo), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION portal_informe(p_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE
    v_negocio bigint := portal_negocio();
    v_out     jsonb;
BEGIN
    SELECT jsonb_build_object('id', e.id, 'servicio', s.nombre,
             'fecha', e.inicio, 'texto', e.texto)
      INTO v_out
    FROM ejecuciones e LEFT JOIN servicios s ON s.codigo = e.servicio_codigo
    WHERE e.id = p_id AND e.negocio_id = v_negocio AND e.estado = 'completada';

    RETURN coalesce(v_out, jsonb_build_object('error', 'no_existe'));
END;
$$;

-- =============================================================================
-- 6. Permisos: lo mínimo, y nada de tablas
-- =============================================================================

REVOKE ALL ON SCHEMA public FROM portal_anon, portal_usuario;
GRANT USAGE ON SCHEMA public TO portal_anon, portal_usuario;

-- Por si alguna función quedó con el EXECUTE público de PUBLIC.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM portal_anon, portal_usuario;

GRANT EXECUTE ON FUNCTION portal_sesion_abrir(text) TO portal_anon;

GRANT EXECUTE ON FUNCTION
      portal_perfil(),
      portal_conocimiento(text),
      portal_conocimiento_guardar(text, text, text, text, jsonb, bigint, bigint),
      portal_conocimiento_borrar(bigint),
      portal_pendientes(),
      portal_informes(int),
      portal_informe(bigint)
  TO portal_usuario;

-- =============================================================================
-- 7. El comando /portal
-- =============================================================================
-- La URL base la escribe el registrador cuando descubre el túnel (en la nube la
-- fija bin/preparar-portal.sh desde WEBHOOK_URL). El token va en el fragmento
-- (#t=) y no en la query: así no queda en los logs del proxy ni en el Referer.

INSERT INTO parametros (negocio_id, clave, valor)
VALUES (NULL, 'portal_url_base', '""'::jsonb)
ON CONFLICT (clave) WHERE negocio_id IS NULL DO NOTHING;

INSERT INTO plantillas (clave, cuerpo, formato, variables, crudas, teclado) VALUES
('portal.enlace',
 '🔐 <a href="{{url}}">Abrí tu portal</a>

El enlace sirve <b>una sola vez</b> y vence en 15 minutos. Si se te vence, pedime otro con /portal.',
 'html', '["url"]'::jsonb, '[]'::jsonb, '[]'::jsonb),

('portal.sin_url',
 'Todavía no tengo configurada la dirección del portal. Avisale a soporte.',
 'html', '[]'::jsonb, '[]'::jsonb, '[]'::jsonb)

ON CONFLICT (clave) DO UPDATE
  SET cuerpo = EXCLUDED.cuerpo, formato = EXCLUDED.formato,
      variables = EXCLUDED.variables, crudas = EXCLUDED.crudas,
      teclado = EXCLUDED.teclado, activo = true,
      version = plantillas.version + 1;

-- El router: un comando más, sin tocar la máquina de estados. Se resuelve antes
-- que /saber y /cancelar por la misma razón que ellos, y devuelve de una.
CREATE OR REPLACE FUNCTION router_portal(p_usuario_id bigint, p_chat_id bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_base  text := btrim(coalesce(parametro(NULL, 'portal_url_base') #>> '{}', ''));
    v_token text;
BEGIN
    IF v_base = '' THEN
        RETURN router_respuesta(p_chat_id, 'portal.sin_url');
    END IF;
    v_token := portal_token_crear(p_usuario_id);
    RETURN router_respuesta(p_chat_id, 'portal.enlace',
             jsonb_build_object('url', rtrim(v_base, '/') || '/portal/#t=' || v_token));
END;
$$;

-- Router v4: idéntico al de la 030 salvo el bloque /portal marcado abajo.
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
