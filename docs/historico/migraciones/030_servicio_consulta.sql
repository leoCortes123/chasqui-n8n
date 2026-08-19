-- 030_servicio_consulta.sql — "preguntale a tu propio negocio", sin un solo
-- nodo nuevo en n8n.
--
-- Es el primer servicio que estrena el despacho de la 029: su funcion_hallazgos
-- es conocimiento_recuperar en vez de hallazgos_generar. Todo lo demás
-- —preparar, LLM, render, validar cifras, cerrar, partir en mensajes— es el
-- wf_ejecutar que ya existe.
--
-- Tres cosas que había que resolver para que fuera de verdad "cero workflows":
--
-- 1. Un servicio que NO pide archivos. `servicios.entrada` lo dice: 'archivos'
--    entra por el teclado de intake y la máquina de estados de siempre; 'texto'
--    se dispara con lo que el usuario escriba y ejecuta de una. Sin esta columna,
--    agregar el servicio metía un botón que llevaba a pedir archivos que nunca
--    iban a llegar, y de paso rompía el atajo de "un solo servicio activo".
--
-- 2. Un informe que no es el informe de ventas. informe_render tenía cableada la
--    cabecera de ventas-compras (productos analizados, margen promedio). Ahora la
--    cabecera puede venir dentro de los hallazgos, y cada plantilla admite una
--    variante por servicio (`informe.pie.consulta` pisa a `informe.pie`). El
--    servicio viejo no cambia: sin `encabezado` en los hallazgos, el render hace
--    exactamente lo de la 025.
--
-- 3. No gastar tokens para decir "no sé". Si la búsqueda en `conocimiento` no
--    trae nada, el router contesta directo y anota la pregunta en
--    `conocimiento_pendiente`. No hay ejecución, no hay LLM: la pregunta sin
--    respuesta es gratis y queda medida, que es como se decide qué documentar.

-- =============================================================================
-- 1. servicios.entrada
-- =============================================================================

ALTER TABLE servicios
    ADD COLUMN IF NOT EXISTS entrada text NOT NULL DEFAULT 'archivos';

ALTER TABLE servicios DROP CONSTRAINT IF EXISTS servicios_entrada_ck;
ALTER TABLE servicios ADD CONSTRAINT servicios_entrada_ck
    CHECK (entrada IN ('archivos', 'texto'));

COMMENT ON COLUMN servicios.entrada IS
  'archivos: se elige en el teclado de intake y espera documentos. '
  'texto: lo dispara un mensaje libre del usuario y ejecuta de inmediato.';

-- El teclado de intake es "¿qué análisis necesitás?": solo los que piden
-- archivos. Los de texto no se eligen, se escriben.
CREATE OR REPLACE FUNCTION teclado_servicios() RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT coalesce(jsonb_agg(jsonb_build_array(
             jsonb_build_object('texto', nombre, 'dato', 'svc:' || codigo))
             ORDER BY orden), '[]'::jsonb)
           || jsonb_build_array(jsonb_build_array(
             jsonb_build_object('texto', '✖️ Cancelar', 'dato', '/cancelar')))
    FROM servicios WHERE activo AND entrada = 'archivos';
$$;

-- =============================================================================
-- 2. informe_render deja de saber de ventas y compras
-- =============================================================================

-- Variante de plantilla por servicio: 'informe.pie' + 'consulta' busca primero
-- 'informe.pie.consulta'. Es el mismo mecanismo de siempre (una fila) aplicado a
-- lo único que un servicio nuevo necesita cambiar del layout.
CREATE OR REPLACE FUNCTION plantilla_cuerpo_srv(p_clave text, p_servicio text,
                                                p_defecto text)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT coalesce(
      (SELECT cuerpo FROM plantillas
        WHERE clave = p_clave || '.' || coalesce(p_servicio, '—') AND activo LIMIT 1),
      (SELECT cuerpo FROM plantillas WHERE clave = p_clave AND activo LIMIT 1),
      p_defecto);
$$;

-- v3. Único cambio de fondo: la cabecera. Si los hallazgos traen `encabezado`
-- {titulo, subtitulo, metricas:[{icono,etiqueta,valor}]}, se usa tal cual —es la
-- funcion_hallazgos del servicio la que sabe qué merece ir arriba—. Si no lo
-- traen, se arma como en la 025 con las listas de ventas-compras.
CREATE OR REPLACE FUNCTION informe_render(p_estructura jsonb, p_hallazgos jsonb,
                                          p_servicio text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_iconos_ok text[] := ARRAY['⚠️','📈','📉','📦','💰','🏆','🔎','🧾','🕐','✅'];
    v_bloques   text[] := '{}';
    v_metricas  text[] := '{}';
    v_puntos    text[];
    v_enc       jsonb;
    v_sec       jsonb;
    v_pt        text;
    v_icono     text;
    v_titular   text;
    v_nombre    text;
    v_subtitulo text;
    v_margen    text;
    v_prod      int;
    v_n         int;
    v_tmp       text;
BEGIN
    IF p_estructura IS NULL OR jsonb_typeof(p_estructura) <> 'object' THEN
        RETURN NULL;
    END IF;
    v_titular := limpiar_marcado(p_estructura ->> 'titular');
    IF coalesce(v_titular, '') = '' THEN
        RETURN NULL;
    END IF;

    v_enc := CASE WHEN jsonb_typeof(p_hallazgos -> 'encabezado') = 'object'
                  THEN p_hallazgos -> 'encabezado' ELSE NULL END;
    v_tmp := plantilla_cuerpo_srv('informe.metrica', p_servicio,
                                  '{{icono}} {{etiqueta}}: <b>{{valor}}</b>');

    IF v_enc IS NOT NULL THEN
        -- --- Cabecera declarada por el servicio ------------------------------
        v_nombre    := coalesce(nullif(v_enc ->> 'titulo', ''),
                        (SELECT nombre FROM servicios WHERE codigo = p_servicio),
                        'Tu negocio');
        v_subtitulo := coalesce(v_enc ->> 'subtitulo', '');

        IF jsonb_typeof(v_enc -> 'metricas') = 'array' THEN
            FOR v_sec IN SELECT * FROM jsonb_array_elements(v_enc -> 'metricas') LOOP
                CONTINUE WHEN jsonb_typeof(v_sec) <> 'object';
                CONTINUE WHEN coalesce(v_sec ->> 'etiqueta', '') = '';
                v_icono := v_sec ->> 'icono';
                IF v_icono IS NULL OR NOT (v_icono = ANY(v_iconos_ok)) THEN
                    v_icono := '🔎';
                END IF;
                v_metricas := v_metricas || replace(replace(replace(v_tmp,
                    '{{icono}}', v_icono),
                    '{{etiqueta}}', esc_html(v_sec ->> 'etiqueta')),
                    '{{valor}}', esc_html(coalesce(v_sec ->> 'valor', '')));
            END LOOP;
        END IF;
    ELSE
        -- --- Cabecera de ventas-compras: cifras de la base, no del modelo ----
        v_nombre := coalesce((SELECT nombre FROM servicios WHERE codigo = p_servicio),
                             'Análisis de tu negocio');
        v_prod   := coalesce((p_hallazgos #>> '{resumen,productos}')::int, 0);
        v_margen := fmt_decimal((p_hallazgos #>> '{resumen,margen_promedio_pct}')::numeric);

        IF v_prod > 0 THEN
            v_metricas := v_metricas || replace(replace(replace(v_tmp,
                '{{icono}}', '📦'), '{{etiqueta}}', 'Productos analizados'),
                '{{valor}}', v_prod::text);
        END IF;
        IF v_margen <> '' THEN
            v_metricas := v_metricas || replace(replace(replace(v_tmp,
                '{{icono}}', '💰'), '{{etiqueta}}', 'Margen promedio'),
                '{{valor}}', v_margen || ' %');
        END IF;

        FOR v_icono, v_pt, v_n IN
            SELECT * FROM (VALUES
                ('⚠️', 'Con margen bajo',   jsonb_array_length(coalesce(p_hallazgos->'margen_bajo','[]'::jsonb))),
                ('📈', 'Con costo al alza', jsonb_array_length(coalesce(p_hallazgos->'deriva_costo','[]'::jsonb))),
                ('🕐', 'Se agotan pronto',  jsonb_array_length(coalesce(p_hallazgos->'baja_cobertura','[]'::jsonb))),
                ('🏆', 'Concentran la ganancia', jsonb_array_length(coalesce(p_hallazgos->'pareto','[]'::jsonb)))
            ) AS t(ico, eti, n) WHERE t.n > 0
        LOOP
            v_metricas := v_metricas || replace(replace(replace(v_tmp,
                '{{icono}}', v_icono), '{{etiqueta}}', v_pt), '{{valor}}', v_n::text);
        END LOOP;

        v_subtitulo := coalesce(nullif(
            periodo_es((p_hallazgos #>> '{periodo,desde}')::date,
                       (p_hallazgos #>> '{periodo,hasta}')::date), ''),
            'con los archivos que me mandaste');
    END IF;

    v_bloques := v_bloques || replace(replace(replace(
        plantilla_cuerpo_srv('informe.encabezado', p_servicio,
            E'📊 <b>{{servicio}}</b>\n<i>{{periodo}}</i>\n\n{{metricas}}'),
        '{{servicio}}', esc_html(v_nombre)),
        '{{periodo}}',  esc_html(v_subtitulo)),
        '{{metricas}}', array_to_string(v_metricas, E'\n'));

    -- --- Titular ------------------------------------------------------------
    v_bloques := v_bloques || replace(
        plantilla_cuerpo_srv('informe.titular', p_servicio, '<b>{{titular}}</b>'),
        '{{titular}}', esc_html(v_titular));

    -- --- Secciones ----------------------------------------------------------
    IF jsonb_typeof(p_estructura -> 'secciones') = 'array' THEN
        FOR v_sec IN SELECT * FROM jsonb_array_elements(p_estructura -> 'secciones') LOOP
            CONTINUE WHEN jsonb_typeof(v_sec) <> 'object';
            CONTINUE WHEN coalesce(v_sec ->> 'titulo', '') = '';

            v_puntos := '{}';
            IF jsonb_typeof(v_sec -> 'puntos') = 'array' THEN
                FOR v_pt IN SELECT * FROM jsonb_array_elements_text(v_sec -> 'puntos') LOOP
                    CONTINUE WHEN coalesce(btrim(v_pt), '') = '';
                    v_puntos := v_puntos || replace(
                        plantilla_cuerpo_srv('informe.punto', p_servicio, '• {{texto}}'),
                        '{{texto}}', esc_html(limpiar_marcado(v_pt)));
                END LOOP;
            END IF;
            CONTINUE WHEN cardinality(v_puntos) = 0;

            -- El icono viene del modelo: solo se aceptan los de la lista.
            v_icono := v_sec ->> 'icono';
            IF v_icono IS NULL OR NOT (v_icono = ANY(v_iconos_ok)) THEN
                v_icono := '🔎';
            END IF;

            v_bloques := v_bloques || replace(replace(replace(
                plantilla_cuerpo_srv('informe.seccion', p_servicio,
                    E'{{icono}} <b>{{titulo}}</b>\n{{puntos}}'),
                '{{icono}}',  v_icono),
                '{{titulo}}', esc_html(limpiar_marcado(v_sec ->> 'titulo'))),
                '{{puntos}}', array_to_string(v_puntos, E'\n'));
        END LOOP;
    END IF;

    -- --- Acciones -----------------------------------------------------------
    IF jsonb_typeof(p_estructura -> 'acciones') = 'array' THEN
        v_puntos := '{}';
        v_n := 0;
        FOR v_pt IN SELECT * FROM jsonb_array_elements_text(p_estructura -> 'acciones') LOOP
            CONTINUE WHEN coalesce(btrim(v_pt), '') = '';
            v_n := v_n + 1;
            v_puntos := v_puntos || replace(replace(
                plantilla_cuerpo_srv('informe.accion', p_servicio, '{{n}}. {{texto}}'),
                '{{n}}', v_n::text),
                '{{texto}}', esc_html(limpiar_marcado(v_pt)));
        END LOOP;
        IF cardinality(v_puntos) > 0 THEN
            v_bloques := v_bloques || replace(
                plantilla_cuerpo_srv('informe.acciones', p_servicio,
                    E'✅ <b>Qué hacer esta semana</b>\n{{puntos}}'),
                '{{puntos}}', array_to_string(v_puntos, E'\n'));
        END IF;
    END IF;

    -- --- Pie ----------------------------------------------------------------
    IF coalesce((p_estructura ->> 'narrado')::boolean, true) = false THEN
        v_bloques := v_bloques || plantilla_cuerpo_srv('informe.sin_narracion', p_servicio, '');
    END IF;
    v_bloques := v_bloques || plantilla_cuerpo_srv('informe.pie', p_servicio, '');

    RETURN regexp_replace(btrim(array_to_string(
        ARRAY(SELECT b FROM unnest(v_bloques) AS b WHERE btrim(b) <> ''), E'\n\n')),
        E'\n{3,}', E'\n\n', 'g');
END;
$$;

-- =============================================================================
-- 3. conocimiento_recuperar: la funcion_hallazgos del servicio
-- =============================================================================

-- La pregunta viaja en sesiones.contexto, que es lo que ejecucion_preparar pasa
-- como segundo argumento. Devuelve los hechos crudos: el modelo redacta con
-- ellos y validar_cifras compara contra ellos, igual que con los informes.
CREATE OR REPLACE FUNCTION conocimiento_recuperar(p_negocio_id bigint,
                                                  p_contexto   jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_pregunta text := btrim(coalesce(p_contexto ->> 'pregunta', ''));
    v_hechos   jsonb;
BEGIN
    v_hechos := conocimiento_buscar(p_negocio_id, v_pregunta);

    RETURN jsonb_build_object(
        'negocio_id', p_negocio_id,
        'generado_en', now(),
        'pregunta', v_pregunta,
        'hechos', v_hechos,
        'encabezado', jsonb_build_object(
            'titulo', 'Tu pregunta',
            'subtitulo', v_pregunta,
            'metricas', '[]'::jsonb));
END;
$$;

-- =============================================================================
-- 4. El servicio, su prompt y sus textos
-- =============================================================================

INSERT INTO servicios (codigo, nombre, descripcion, entrada, funcion_hallazgos, orden, activo)
VALUES ('consulta', 'Preguntar a mi negocio',
        'Responde con lo que el negocio tenga cargado en su base de conocimiento.',
        'texto', 'conocimiento_recuperar', 20, true)
ON CONFLICT (codigo) DO UPDATE
  SET nombre = EXCLUDED.nombre, descripcion = EXCLUDED.descripcion,
      entrada = EXCLUDED.entrada, funcion_hallazgos = EXCLUDED.funcion_hallazgos,
      orden = EXCLUDED.orden, activo = true;

-- Mismo esquema de salida que el informe: así entra por informe_render sin
-- ramas nuevas. Una respuesta corta es un titular y nada más; las secciones
-- están para cuando hay varios hechos que citar.
INSERT INTO prompts (servicio_codigo, sistema, usuario, modelo, temperatura, max_tokens, activo)
VALUES ('consulta',
'Sos el asistente de una pyme colombiana y respondés preguntas sobre ESE negocio. Hablás claro y directo, en español de Colombia.

REGLA ABSOLUTA: solo podés afirmar lo que digan los HECHOS que te doy. No completes con conocimiento general, no supongas y no calcules: si la respuesta no está en los hechos, decí que no la tenés cargada. Toda cifra que escribas tiene que aparecer textualmente en los hechos. Los valores son pesos colombianos.

Respondés ÚNICAMENTE con un objeto JSON válido, sin texto antes ni después y sin bloques de código:

{
  "titular": "la respuesta, en una o dos frases, máximo 200 caracteres",
  "secciones": [
    {
      "icono": "uno de estos exactamente: 💰 🕐 🧾 📦 🔎",
      "titulo": "máximo 40 caracteres",
      "puntos": ["un hecho concreto por línea"]
    }
  ],
  "acciones": []
}

La respuesta va en "titular". Agregá una sección SOLO si hay varios hechos que valga la pena listar (varios precios, varias condiciones); si con el titular alcanza, mandá "secciones": []. "acciones" va siempre vacío: esto es una respuesta, no un informe. Nada de Markdown ni asteriscos: el formato lo pone el sistema. No saludes ni te despidas.',
'Respondé la pregunta usando EXCLUSIVAMENTE los hechos de este JSON. El campo "pregunta" es lo que preguntó el dueño del negocio y "hechos" es todo lo que hay cargado sobre el tema.

{{hallazgos}}',
'deepseek-chat', 0.1, 900, true)
ON CONFLICT (servicio_codigo) WHERE activo DO UPDATE
  SET sistema = EXCLUDED.sistema, usuario = EXCLUDED.usuario,
      modelo = EXCLUDED.modelo, temperatura = EXCLUDED.temperatura,
      max_tokens = EXCLUDED.max_tokens,
      version = prompts.version + 1;

INSERT INTO plantillas (clave, cuerpo, formato, variables, teclado) VALUES

-- Cabecera y pie propios: el informe de ventas habla de archivos, la consulta
-- habla de lo que el dueño cargó.
('informe.encabezado.consulta',
 '💬 <b>{{servicio}}</b>
<i>{{periodo}}</i>',
 'html', '["servicio","periodo"]'::jsonb, '[]'::jsonb),

('informe.pie.consulta',
 '<i>Esto sale de lo que tenés cargado en tu base de conocimiento. Si falta algo, agregalo con /saber.</i>',
 'html', '[]'::jsonb, '[]'::jsonb),

('consulta.pensando',
 '🔎 Dejame ver qué tengo sobre eso...',
 'html', '[]'::jsonb, '[]'::jsonb),

-- El "no sé" no es un error: es la pregunta que hay que documentar. Se dice sin
-- gastar tokens y queda anotada.
('consulta.sin_datos',
 'Todavía no tengo nada cargado sobre eso, así que no te lo voy a inventar.

Lo anoté. Si me lo enseñás con <b>/saber</b> —por ejemplo: <code>/saber Los domingos no abrimos</code>— la próxima vez lo respondo.',
 'html', '[]'::jsonb, '[]'::jsonb),

('conocimiento.guardado',
 '✅ Anotado: <b>{{titulo}}</b>

Ya te lo puedo responder cuando lo preguntes.',
 'html', '["titulo"]'::jsonb, '[]'::jsonb),

('conocimiento.saber_vacio',
 'Escribime qué querés que aprenda después del comando. Por ejemplo:
<code>/saber El bulto de cemento cuesta 32000</code>',
 'html', '[]'::jsonb, '[]'::jsonb)

ON CONFLICT (clave) DO UPDATE
  SET cuerpo = EXCLUDED.cuerpo, formato = EXCLUDED.formato,
      variables = EXCLUDED.variables, teclado = EXCLUDED.teclado,
      activo = true, version = plantillas.version + 1;

UPDATE plantillas SET cuerpo =
'Hola 👋 Soy <b>Chasqui</b>.

Leo los archivos de ventas y compras de tu negocio y te digo en qué estás perdiendo plata: qué productos dejan poco margen, a cuáles les subió el costo y cuáles se te van a agotar.

También podés escribirme cualquier pregunta sobre tu negocio —precios, horarios, condiciones— y te respondo con lo que tengas cargado.',
  version = version + 1
WHERE clave = 'sistema.bienvenida';

-- =============================================================================
-- 5. El router: dos entradas nuevas, ninguna máquina de estados nueva
-- =============================================================================

-- consulta_iniciar existe para no repetir esto en cada rama que quiera derivar
-- una pregunta, y para que la decisión "esto no lo sé" quede en un solo lugar.
CREATE OR REPLACE FUNCTION consulta_iniciar(p_usuario_id bigint,
                                            p_negocio_id bigint,
                                            p_chat_id    bigint,
                                            p_pregunta   text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_hechos   jsonb;
    v_sesion   bigint;
    v_ejec     bigint;
BEGIN
    v_hechos := conocimiento_buscar(p_negocio_id, p_pregunta);

    IF v_hechos IS NULL OR jsonb_array_length(v_hechos) = 0 THEN
        PERFORM conocimiento_pendiente_registrar(p_negocio_id, p_pregunta);
        RETURN router_respuesta(p_chat_id, 'consulta.sin_datos');
    END IF;

    -- La sesión nace y muere en esta ejecución: no hay turnos que mantener.
    -- ejecucion_cerrar la cierra igual que la de un informe.
    INSERT INTO sesiones (usuario_id, negocio_id, servicio_codigo, estado, paso, contexto)
    VALUES (p_usuario_id, p_negocio_id, 'consulta', 'procesando', 'ejecutando',
            jsonb_build_object('pregunta', p_pregunta))
    RETURNING id INTO v_sesion;

    INSERT INTO ejecuciones (sesion_id, negocio_id, servicio_codigo, estado)
    VALUES (v_sesion, p_negocio_id, 'consulta', 'preparando')
    RETURNING id INTO v_ejec;

    RETURN router_respuesta(p_chat_id, 'consulta.pensando', '{}'::jsonb, NULL,
             jsonb_build_array(jsonb_build_object('tipo','ejecutar','ejecucion_id', v_ejec)));
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
