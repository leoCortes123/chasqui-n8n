-- 029_servicios_identidades_conocimiento.sql — los tres cimientos de la Fase 1
-- del plan de producción (docs/PLAN_PRODUCCION.md). Ninguno agrega workflows:
-- los tres convierten en filas cosas que hoy están cableadas.
--
-- 1. servicios.funcion_hallazgos — hoy ejecucion_preparar llama hallazgos_generar
--    con el nombre escrito en el código (008:45). Cualquier servicio nuevo con
--    otros números recibiría los hallazgos de ventas-compras. Es el bloqueador #1
--    del plan: sin esta columna, cada servicio nuevo toca n8n.
--
-- 2. identidades — usuarios.telegram_user_id es la identidad del sistema. Para
--    que exista WhatsApp (Fase 3) y la sesión del portal (Fase 1) hace falta un
--    usuario con varias identidades, no una columna por canal.
--
-- 3. conocimiento / conocimiento_pendiente — lo que el negocio sabe de sí mismo
--    y, sobre todo, lo que no supo contestar. Esa segunda tabla es el motor:
--    no se le pide al dueño que documente su negocio, se le cosechan las
--    preguntas reales ordenadas por frecuencia.
--
-- Nota sobre validar_cifras: NO hace falta tocarla. Valida contra el jsonb que
-- le pasa wf_ejecutar, que es lo que devolvió funcion_hallazgos. Al despachar
-- por servicio, las cifras del cotizador o de la consulta entran por el mismo
-- camino que las de ventas-compras y quedan permitidas solas. El cambio #3 de la
-- sección 5 del plan se resuelve sin código.

-- =============================================================================
-- 1. servicios.funcion_hallazgos
-- =============================================================================

ALTER TABLE servicios
    ADD COLUMN IF NOT EXISTS funcion_hallazgos text NOT NULL
        DEFAULT 'hallazgos_generar';

COMMENT ON COLUMN servicios.funcion_hallazgos IS
  'Función que arma el jsonb de hallazgos del servicio. Firma obligatoria: '
  '(p_negocio_id bigint, p_contexto jsonb) RETURNS jsonb.';

-- La firma del despacho es de dos argumentos: el segundo es el contexto de la
-- sesión, que es de donde un servicio conversacional (consulta, cotizador) saca
-- la pregunta del usuario. hallazgos_generar no lo necesita, pero tiene que
-- aceptarlo para entrar por el mismo despacho. Sobrecarga, no reemplazo: la
-- versión de un argumento la siguen llamando las pruebas y el back-office.
CREATE OR REPLACE FUNCTION hallazgos_generar(p_negocio_id bigint, p_contexto jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT hallazgos_generar(p_negocio_id);
$$;

-- === ejecucion_preparar (v2: despacha por fila) ==============================
-- Mismo contrato de entrada y salida que la 008; lo único que cambia es de dónde
-- sale el nombre de la función de hallazgos. Se agrega un modo de falla explícito
-- ('sin_funcion_hallazgos'): un servicio mal configurado tiene que decirlo, no
-- reventar con un "function does not exist" dentro de un workflow.
CREATE OR REPLACE FUNCTION ejecucion_preparar(p_ejecucion_id bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_negocio_id bigint;
    v_servicio   text;
    v_sesion_id  bigint;
    v_contexto   jsonb;
    v_funcion    text;
    v_cupo       bigint;
    v_usados     bigint;
    v_hallazgos  jsonb;
    v_prompt     record;
    v_pdf        record;
BEGIN
    SELECT negocio_id, servicio_codigo, sesion_id
      INTO v_negocio_id, v_servicio, v_sesion_id
    FROM ejecuciones WHERE id = p_ejecucion_id;

    -- Control de cupo.
    SELECT cupo_tokens_mes, tokens_mes INTO v_cupo, v_usados
    FROM v_consumo_negocio WHERE negocio_id = v_negocio_id;

    IF v_cupo IS NOT NULL AND v_cupo > 0 AND v_usados >= v_cupo THEN
        UPDATE ejecuciones SET estado = 'bloqueada',
               error = 'cupo mensual superado', fin = now()
        WHERE id = p_ejecucion_id;
        RETURN jsonb_build_object('bloqueado', true, 'limite', v_cupo, 'usados', v_usados);
    END IF;

    SELECT coalesce(contexto, '{}'::jsonb) INTO v_contexto
    FROM sesiones WHERE id = v_sesion_id;
    v_contexto := coalesce(v_contexto, '{}'::jsonb);

    SELECT funcion_hallazgos INTO v_funcion FROM servicios WHERE codigo = v_servicio;

    IF to_regprocedure(format('%I(bigint,jsonb)', coalesce(v_funcion, ''))) IS NULL THEN
        UPDATE ejecuciones SET estado = 'fallida',
               error = format('servicio %s: función de hallazgos inexistente (%s)',
                              v_servicio, coalesce(v_funcion, '—')), fin = now()
        WHERE id = p_ejecucion_id;
        RETURN jsonb_build_object('bloqueado', false, 'error', 'sin_funcion_hallazgos');
    END IF;

    EXECUTE format('SELECT %I($1, $2)', v_funcion)
       INTO v_hallazgos USING v_negocio_id, v_contexto;

    SELECT id, sistema, usuario, modelo, temperatura, max_tokens
      INTO v_prompt
    FROM prompts WHERE servicio_codigo = v_servicio AND activo LIMIT 1;

    IF v_prompt.id IS NULL THEN
        UPDATE ejecuciones SET estado = 'fallida',
               error = format('sin prompt activo para %s', v_servicio), fin = now()
        WHERE id = p_ejecucion_id;
        RETURN jsonb_build_object('bloqueado', false, 'error', 'sin_prompt');
    END IF;

    SELECT id, html, css INTO v_pdf
    FROM plantillas_pdf WHERE servicio_codigo = v_servicio AND activo LIMIT 1;

    UPDATE ejecuciones
    SET hallazgos = v_hallazgos, prompt_id = v_prompt.id, estado = 'procesando'
    WHERE id = p_ejecucion_id;

    RETURN jsonb_build_object(
        'bloqueado', false,
        'ejecucion_id', p_ejecucion_id,
        'hallazgos', v_hallazgos,
        'prompt', jsonb_build_object(
            'id', v_prompt.id, 'sistema', v_prompt.sistema, 'usuario', v_prompt.usuario,
            'modelo', v_prompt.modelo, 'temperatura', v_prompt.temperatura,
            'max_tokens', v_prompt.max_tokens),
        'plantilla_pdf', CASE WHEN v_pdf.id IS NOT NULL
            THEN jsonb_build_object('id', v_pdf.id, 'html', v_pdf.html, 'css', v_pdf.css)
            ELSE NULL END
    );
END;
$$;

-- =============================================================================
-- 2. identidades
-- =============================================================================

-- Un usuario deja de ser "una cuenta de Telegram". telegram_user_id se queda
-- como caché del canal —wf_enviar resuelve chat_id desde usuarios y no vale la
-- pena tocarlo— pero deja de ser obligatorio: un usuario que llegue por WhatsApp
-- o por el portal no tiene uno.
ALTER TABLE usuarios ALTER COLUMN telegram_user_id DROP NOT NULL;

CREATE TABLE IF NOT EXISTS identidades (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    canal      text NOT NULL,           -- telegram | whatsapp | portal
    id_externo text NOT NULL,           -- id de Telegram, teléfono, sub del token
    usuario_id bigint NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    datos      jsonb NOT NULL DEFAULT '{}'::jsonb,   -- chat_id, username, ...
    vista_en   timestamptz NOT NULL DEFAULT now(),
    creada_en  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (canal, id_externo)
);
CREATE INDEX IF NOT EXISTS idx_identidades_usuario ON identidades(usuario_id);

-- Backfill: cada usuario que ya existe tiene su identidad de Telegram.
INSERT INTO identidades (canal, id_externo, usuario_id, datos)
SELECT 'telegram', u.telegram_user_id::text, u.id,
       jsonb_strip_nulls(jsonb_build_object(
         'chat_id', u.telegram_chat_id, 'username', u.telegram_username))
FROM usuarios u
WHERE u.telegram_user_id IS NOT NULL
ON CONFLICT (canal, id_externo) DO NOTHING;

-- === usuario_de_canal ========================================================
-- Localiza o crea el usuario a partir del evento normalizado de CUALQUIER canal.
-- El evento sigue la forma que ya usa el router: {from:{id,username}, chat:{id}}.
CREATE OR REPLACE FUNCTION usuario_de_canal(p_canal text, p_evento jsonb)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_ext   text   := p_evento #>> '{from,id}';
    v_chat  text   := p_evento #>> '{chat,id}';
    v_user  text   := p_evento #>> '{from,username}';
    v_datos jsonb;
    v_id    bigint;
BEGIN
    IF v_ext IS NULL OR btrim(v_ext) = '' THEN
        RAISE EXCEPTION 'usuario_de_canal(%): el evento no trae from.id', p_canal;
    END IF;

    v_datos := jsonb_strip_nulls(jsonb_build_object(
                 'chat_id', v_chat, 'username', v_user));

    SELECT usuario_id INTO v_id FROM identidades
    WHERE canal = p_canal AND id_externo = v_ext;

    IF v_id IS NULL THEN
        -- Usuario nuevo. En Telegram se rellenan además las columnas caché para
        -- no romper a wf_enviar, que resuelve el chat_id desde usuarios.
        INSERT INTO usuarios (telegram_user_id, telegram_chat_id, telegram_username)
        VALUES (CASE WHEN p_canal = 'telegram' THEN v_ext::bigint END,
                CASE WHEN p_canal = 'telegram' THEN v_chat::bigint END,
                CASE WHEN p_canal = 'telegram' THEN v_user END)
        RETURNING id INTO v_id;

        INSERT INTO identidades (canal, id_externo, usuario_id, datos)
        VALUES (p_canal, v_ext, v_id, v_datos)
        -- Carrera con otro webhook del mismo usuario: gana el que insertó
        -- primero y el usuario recién creado queda huérfano, no duplicado.
        ON CONFLICT (canal, id_externo)
          DO UPDATE SET vista_en = now(), datos = identidades.datos || EXCLUDED.datos
        RETURNING usuario_id INTO v_id;
    ELSE
        UPDATE identidades SET vista_en = now(), datos = datos || v_datos
        WHERE canal = p_canal AND id_externo = v_ext;
    END IF;

    IF p_canal = 'telegram' THEN
        UPDATE usuarios SET
            telegram_chat_id  = coalesce(v_chat::bigint, telegram_chat_id),
            telegram_username = coalesce(v_user, telegram_username)
        WHERE id = v_id;
    END IF;

    RETURN v_id;
END;
$$;

-- usuario_de_telegram queda como el nombre que llama el router: mismo contrato,
-- ahora delegando. Así este cambio no toca router_procesar_mensaje.
CREATE OR REPLACE FUNCTION usuario_de_telegram(p_evento jsonb)
RETURNS bigint LANGUAGE sql AS $$
    SELECT usuario_de_canal('telegram', p_evento);
$$;

-- =============================================================================
-- 3. conocimiento y conocimiento_pendiente
-- =============================================================================

-- Lo que el negocio sabe de sí mismo: precios, políticas, horarios, condiciones.
-- `datos` guarda la cifra estructurada cuando la hay ({valor, unidad, ...}); el
-- LLM narra desde `contenido` y nunca calcula, igual que en los informes.
CREATE TABLE IF NOT EXISTS conocimiento (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    negocio_id      bigint NOT NULL REFERENCES negocios(id),
    tipo            text NOT NULL,     -- precio | politica | horario | faq | condicion
    clave           text,              -- id estable dentro del negocio (SKU, código)
    titulo          text NOT NULL,
    contenido       text,
    datos           jsonb NOT NULL DEFAULT '{}'::jsonb,
    origen          text NOT NULL DEFAULT 'portal',   -- chat | portal | archivo
    vigente_desde   date NOT NULL DEFAULT current_date,
    vigente_hasta   date,
    actualizado_en  timestamptz NOT NULL DEFAULT now(),
    actualizado_por bigint REFERENCES usuarios(id)
);

-- Con clave, el mismo hecho se pisa en vez de duplicarse: es lo que permite
-- reimportar la lista de precios en Excel sin ensuciar la base.
CREATE UNIQUE INDEX IF NOT EXISTS uq_conocimiento_clave
    ON conocimiento(negocio_id, tipo, clave) WHERE clave IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_conocimiento_negocio ON conocimiento(negocio_id, tipo);

-- Recuperación v1 sin pgvector: trigramas sobre título + contenido normalizados.
-- Para <300 filas por negocio esto es más barato y más depurable que embeddings.
CREATE INDEX IF NOT EXISTS idx_conocimiento_texto_trgm ON conocimiento
    USING gin ((norm_texto(titulo || ' ' || coalesce(contenido, ''))) gin_trgm_ops);

-- Cada pregunta que el bot no supo contestar. Ordenada por `veces`, es la lista
-- de qué construir después: la decide el uso, no la intuición.
CREATE TABLE IF NOT EXISTS conocimiento_pendiente (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    negocio_id    bigint NOT NULL REFERENCES negocios(id),
    pregunta      text NOT NULL,
    pregunta_norm text NOT NULL,
    veces         int NOT NULL DEFAULT 1,
    resuelto_por  bigint REFERENCES conocimiento(id),
    primera_en    timestamptz NOT NULL DEFAULT now(),
    ultima_en     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (negocio_id, pregunta_norm)
);

-- === conocimiento_buscar =====================================================
-- Top-N de hechos vigentes por parecido con la pregunta. Devuelve jsonb porque
-- quien lo consume es un prompt, no una consulta SQL.
--
-- El parecido se mide contra título y contenido por separado y gana el mejor:
-- un contenido largo diluye la similitud de trigramas y hundiría el hecho que
-- justamente tiene la respuesta.
CREATE OR REPLACE FUNCTION conocimiento_buscar(p_negocio_id bigint,
                                               p_texto      text,
                                               p_limite     int DEFAULT 8,
                                               p_umbral     numeric DEFAULT 0.12)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    WITH q AS (SELECT norm_texto(p_texto) AS t)
    SELECT coalesce(jsonb_agg(x ORDER BY x -> 'parecido' DESC), '[]'::jsonb)
    FROM (
        SELECT jsonb_build_object(
                 'id', c.id, 'tipo', c.tipo, 'clave', c.clave,
                 'titulo', c.titulo, 'contenido', c.contenido, 'datos', c.datos,
                 'parecido', round(greatest(
                     similarity(norm_texto(c.titulo), q.t),
                     similarity(norm_texto(coalesce(c.contenido, '')), q.t))::numeric, 3)
               ) AS x
        FROM conocimiento c, q
        WHERE c.negocio_id = p_negocio_id
          AND c.vigente_desde <= current_date
          AND (c.vigente_hasta IS NULL OR c.vigente_hasta >= current_date)
          AND (q.t = '' OR greatest(
                 similarity(norm_texto(c.titulo), q.t),
                 similarity(norm_texto(coalesce(c.contenido, '')), q.t)) >= p_umbral)
        ORDER BY greatest(
                   similarity(norm_texto(c.titulo), q.t),
                   similarity(norm_texto(coalesce(c.contenido, '')), q.t)) DESC,
                 c.actualizado_en DESC
        LIMIT greatest(p_limite, 1)
    ) s;
$$;

-- === conocimiento_pendiente_registrar ========================================
-- norm_texto no alcanza para agrupar preguntas: deja los signos, y entonces
-- "¿a qué hora abren?" y "a que hora abren" son dos filas de una vez en vez de
-- una de dos veces —justo el conteo que decide qué se documenta primero—.
CREATE OR REPLACE FUNCTION norm_pregunta(p text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT btrim(regexp_replace(
             regexp_replace(norm_texto(p), '[^a-z0-9ñ ]', '', 'g'), '\s+', ' ', 'g'));
$$;

-- Se llama cuando la búsqueda no trajo nada útil. Idempotente por pregunta
-- normalizada: la misma duda hecha diez veces es una fila con veces=10.
CREATE OR REPLACE FUNCTION conocimiento_pendiente_registrar(p_negocio_id bigint,
                                                            p_pregunta   text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_norm text := norm_pregunta(p_pregunta);
    v_id   bigint;
BEGIN
    IF p_negocio_id IS NULL OR v_norm = '' THEN RETURN NULL; END IF;

    INSERT INTO conocimiento_pendiente (negocio_id, pregunta, pregunta_norm)
    VALUES (p_negocio_id, btrim(p_pregunta), v_norm)
    ON CONFLICT (negocio_id, pregunta_norm) DO UPDATE
      SET veces = conocimiento_pendiente.veces + 1, ultima_en = now()
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

-- === conocimiento_guardar ====================================================
-- Alta o actualización de un hecho. Es la puerta única: el portal, /saber y el
-- parseo de archivos entran todos por acá, así que la regla de upsert está en
-- un solo lugar.
CREATE OR REPLACE FUNCTION conocimiento_guardar(p_negocio_id bigint,
                                                p_tipo       text,
                                                p_titulo     text,
                                                p_contenido  text DEFAULT NULL,
                                                p_clave      text DEFAULT NULL,
                                                p_datos      jsonb DEFAULT '{}'::jsonb,
                                                p_origen     text DEFAULT 'portal',
                                                p_usuario_id bigint DEFAULT NULL,
                                                p_pendiente_id bigint DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_id bigint;
BEGIN
    IF p_clave IS NOT NULL THEN
        INSERT INTO conocimiento (negocio_id, tipo, clave, titulo, contenido,
                                  datos, origen, actualizado_por)
        VALUES (p_negocio_id, p_tipo, p_clave, p_titulo, p_contenido,
                coalesce(p_datos, '{}'::jsonb), p_origen, p_usuario_id)
        -- El índice único es parcial (solo filas con clave), así que la
        -- inferencia del ON CONFLICT tiene que repetir su predicado.
        ON CONFLICT (negocio_id, tipo, clave) WHERE clave IS NOT NULL DO UPDATE
          SET titulo = EXCLUDED.titulo, contenido = EXCLUDED.contenido,
              datos = EXCLUDED.datos, origen = EXCLUDED.origen,
              actualizado_en = now(), actualizado_por = EXCLUDED.actualizado_por,
              vigente_hasta = NULL
        RETURNING id INTO v_id;
    ELSE
        INSERT INTO conocimiento (negocio_id, tipo, titulo, contenido,
                                  datos, origen, actualizado_por)
        VALUES (p_negocio_id, p_tipo, p_titulo, p_contenido,
                coalesce(p_datos, '{}'::jsonb), p_origen, p_usuario_id)
        RETURNING id INTO v_id;
    END IF;

    -- Una pendiente se marca resuelta cuando ALGUIEN dice que este hecho la
    -- responde, nunca por parecido. Cerrarla sola con un umbral de trigramas
    -- esconde el vacío justo en la tabla que existe para mostrarlo; las
    -- coincidencias probables se sugieren en v_conocimiento_faltante, que no
    -- borra nada.
    IF p_pendiente_id IS NOT NULL THEN
        UPDATE conocimiento_pendiente
        SET resuelto_por = v_id
        WHERE id = p_pendiente_id AND negocio_id = p_negocio_id;
    END IF;

    RETURN v_id;
END;
$$;

-- === Vistas de operación =====================================================
-- Qué falta documentar, y con qué hecho existente PODRÍA ya estar respondido.
-- word_similarity mide cuánto de la pregunta aparece dentro del hecho, que es
-- la comparación correcta cuando uno de los dos textos es mucho más largo.
CREATE OR REPLACE VIEW v_conocimiento_faltante AS
SELECT p.id, p.negocio_id, n.nombre AS negocio, p.pregunta, p.veces,
       p.primera_en, p.ultima_en,
       s.id AS candidato_id, s.titulo AS candidato, s.parecido
FROM conocimiento_pendiente p
JOIN negocios n ON n.id = p.negocio_id
LEFT JOIN LATERAL (
    SELECT c.id, c.titulo,
           round(word_similarity(p.pregunta_norm,
                   norm_texto(c.titulo || ' ' || coalesce(c.contenido, '')))::numeric, 3)
             AS parecido
    FROM conocimiento c
    WHERE c.negocio_id = p.negocio_id
      AND word_similarity(p.pregunta_norm,
            norm_texto(c.titulo || ' ' || coalesce(c.contenido, ''))) >= 0.30
    ORDER BY parecido DESC
    LIMIT 1
) s ON true
WHERE p.resuelto_por IS NULL
ORDER BY p.veces DESC, p.ultima_en DESC;

CREATE OR REPLACE VIEW v_conocimiento_cobertura AS
SELECT n.id AS negocio_id, n.nombre AS negocio,
       count(c.id)                                              AS hechos,
       count(c.id) FILTER (WHERE c.tipo = 'precio')             AS precios,
       count(c.id) FILTER (WHERE c.origen = 'chat')             AS desde_chat,
       (SELECT count(*) FROM conocimiento_pendiente p
         WHERE p.negocio_id = n.id AND p.resuelto_por IS NULL)  AS pendientes,
       max(c.actualizado_en)                                    AS ultimo_cambio
FROM negocios n
LEFT JOIN conocimiento c ON c.negocio_id = n.id
GROUP BY n.id, n.nombre;
