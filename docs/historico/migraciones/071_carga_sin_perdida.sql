-- 071_carga_sin_perdida.sql — ningún archivo que el usuario mande se pierde,
-- y la carga entera cabe en un solo mensaje.
--
-- EL PROBLEMA, MEDIDO EN LA SEGUNDA PRUEBA DE USUARIO
--
-- El usuario mandó 101 archivos. Telegram entregó los 101 —está en el log del
-- proxy: 101 POST a /webhook/telegram con payload de documento, todos 200, a
-- ~3,6/s entre las 15:52:20 y las 15:52:48 UTC—. Llegaron a `documentos` 63.
--
-- Los 38 que faltan no se perdieron en la red ni en la ingesta. Los descartó el
-- despachador, acá (056):
--
--     IF v_sesion.estado = 'procesando' THEN
--         RETURN router_respuesta(v_chat_id, 'ejecucion.ya_en_curso');
--     END IF;
--
-- Ese RETURN está ANTES de `router_h_recibiendo`, que es el único que emite la
-- acción `ingerir`. El usuario tocó Analizar a las 15:52:37 con 38 archivos
-- todavía en vuelo; a partir de ahí cada documento se contestó y se tiró. La
-- cuenta cierra exacto: los updates desde 15:52:39 (34) más el segundo 15:52:34,
-- que tuvo 4 webhooks y 0 documentos.
--
-- Y la respuesta que recibieron esos 38 fue:
--
--     ⏳ Ya estoy trabajando en tu informe. Aguantame un momento.
--
-- que no dice en ninguna parte que el archivo se descartó. Entre 63 confirmaciones
-- y 38 de esas, la lectura natural es que entró todo. El sistema no mintió a
-- propósito; simplemente nunca dijo la verdad.
--
-- LAS TRES REGLAS QUE SALEN DE AHÍ
--
--   1. Un archivo que llega SIEMPRE se guarda. No hay estado de la conversación
--      en el que un documento se conteste y se tire. Pedirle al usuario que
--      vuelva a buscar 60 archivos entre sus carpetas es perderlo como usuario.
--   2. Analizar no arranca mientras estén llegando archivos. El botón no dispara:
--      agenda. La corrida empieza cuando pasaron `carga_silencio_segundos` sin que
--      entre nada nuevo.
--   3. La carga entera se cuenta en UN mensaje que se edita en su lugar, no en un
--      mensaje por archivo. Un chat con 101 confirmaciones iguales produce la
--      misma desconfianza que el error que estamos arreglando.
--
-- POR QUÉ EL PANEL Y NO LA PREGUNTA "¿SON TODOS?"
--
-- La 042 ya había sacado el mensaje por archivo y lo había reemplazado por un
-- debounce que pregunta "¿son todos?" cuando el usuario deja de mandar. Eso
-- resolvía la metralleta pero no la certificación: la pregunta no dice CUÁNTO
-- entró, así que el usuario no tiene con qué comparar contra lo que mandó. El
-- panel es la misma idea llevada hasta el final: un solo mensaje, siempre el
-- mismo, que dice cuántos archivos y cuántos movimientos van, y que trae el
-- botón. La 049 puso ese botón en el mensaje de "mandame los archivos" porque no
-- había mejor lugar; ahora sí lo hay, y encima se fija (`pinChatMessage`) para
-- que el usuario no tenga que volver a buscarlo.
--
-- El debounce de wf_ingesta no se toca en su forma: sigue siendo esperar y
-- preguntar "¿sigo siendo el último?". Lo que cambia es a quién le pregunta —
-- ahora a `carga_evaluar`, que decide entre callarse, refrescar el panel o
-- arrancar el análisis— y que la decisión vive en la base, no en el workflow.
--
-- LO QUE ESTA MIGRACIÓN NO HACE, A PROPÓSITO
--
-- No pone los topes del plan free (movimientos, archivos, informes por mes) ni
-- corrige el consentimiento: eso es 072, y necesita decidir qué pasa con un
-- archivo que entra por encima del tope, que es una conversación distinta. Acá
-- solo se garantiza que el archivo NO SE PIERDE; qué se hace con él después es
-- la migración siguiente.

-- =============================================================================
-- 1. Lo que la sesión necesita recordar
-- =============================================================================
-- `panel_mensaje_id` es el mensaje que se edita en cada refresco. Vive en una
-- columna y no en `contexto` porque los workflows lo leen y lo escriben en cada
-- archivo que entra: una bolsa jsonb para algo que se toca 101 veces en 28
-- segundos es pagar un parseo por nada.
--
-- `analisis_pedido_en` es el botón ya tocado. Que sea una marca de tiempo y no
-- un boolean permite distinguir "lo pidió recién" de "lo pidió hace media hora y
-- algo se colgó", que es lo que va a mirar el reaper cuando haga falta.
ALTER TABLE sesiones
    ADD COLUMN IF NOT EXISTS panel_mensaje_id   bigint,
    ADD COLUMN IF NOT EXISTS analisis_pedido_en timestamptz;

COMMENT ON COLUMN sesiones.panel_mensaje_id IS
  'Mensaje de Telegram del panel de carga. Se edita en su lugar en cada archivo '
  'que entra; NULL = todavía no se mandó. Ver 071_carga_sin_perdida.sql.';
COMMENT ON COLUMN sesiones.analisis_pedido_en IS
  'Cuándo tocó Analizar. El análisis no arranca acá: arranca cuando pasan '
  '`carga_silencio_segundos` sin que entre un archivo nuevo.';

-- Por qué un documento no entró a movimientos, cuando no entró. NULL es el caso
-- normal. La 072 le va a agregar los motivos de tope de plan; acá alcanza con
-- 'sin_sesion', que es el archivo que llega sin carga abierta.
ALTER TABLE documentos
    ADD COLUMN IF NOT EXISTS motivo_pendiente text;

COMMENT ON COLUMN documentos.motivo_pendiente IS
  'Por qué el documento quedó guardado sin cargarse a movimientos. NULL = se '
  'cargó normal. El archivo NUNCA se descarta: se guarda y se explica.';

-- =============================================================================
-- 2. Cuánto silencio hace falta
-- =============================================================================
-- 10 segundos, medido contra la prueba real: Telegram entregó 101 archivos a
-- ~3,6/s, o sea un hueco de ~0,28 s entre archivos. Diez segundos son treinta y
-- cinco veces ese hueco: si pasaron, el usuario terminó de mandar de verdad y no
-- es que Telegram se tomó un respiro. Es parámetro y no literal porque el número
-- correcto depende de la red del usuario y se va a querer subir sin migrar.
DELETE FROM parametros WHERE negocio_id IS NULL AND clave = 'carga_silencio_segundos';
INSERT INTO parametros (negocio_id, clave, valor)
VALUES (NULL, 'carga_silencio_segundos', '10'::jsonb);

-- =============================================================================
-- 3. Qué muestra el panel
-- =============================================================================
-- Los contadores salen de `documentos` y `movimientos`, no de un acumulador: un
-- contador que se incrementa se desincroniza en cuanto una ejecución falla a la
-- mitad, y este mensaje es justamente el que tiene que ser confiable.
--
-- `movimientos` y no `mov_visibles` a propósito: el panel cuenta lo que ENTRÓ,
-- que es lo que el usuario puede comparar contra lo que mandó. Lo que de eso el
-- plan deja analizar es harina de otro costal y lo dice el informe (073).
-- Un archivo que ni siquiera se pudo BAJAR de Telegram no tiene fila en
-- `documentos` —el hash sale del contenido— así que no habría con qué contarlo y
-- volvería a ser una pérdida silenciosa. Se anota en la sesión para que el panel
-- lo nombre. Es el único caso en todo el sistema en el que hay que pedirle al
-- usuario que reenvíe algo, y por eso tiene que verse.
CREATE OR REPLACE FUNCTION carga_registrar_fallo(p_sesion_id bigint,
                                                 p_nombre text)
RETURNS void LANGUAGE sql AS $$
    UPDATE sesiones
       SET contexto = jsonb_set(contexto, '{descargas_fallidas}',
             coalesce(contexto -> 'descargas_fallidas', '[]'::jsonb)
               || to_jsonb(coalesce(nullif(btrim(p_nombre), ''), 'un archivo')),
             true)
     WHERE id = p_sesion_id;
$$;

CREATE OR REPLACE FUNCTION carga_resumen(p_sesion_id bigint)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    WITH d AS (
        SELECT * FROM documentos WHERE sesion_id = p_sesion_id
    ),
    m AS (
        SELECT count(*) AS filas, min(fecha) AS desde, max(fecha) AS hasta
        FROM movimientos WHERE documento_id IN (SELECT id FROM d)
    ),
    f AS (
        SELECT coalesce(s.contexto -> 'descargas_fallidas', '[]'::jsonb) AS j
        FROM sesiones s WHERE s.id = p_sesion_id
    )
    SELECT jsonb_build_object(
        'no_bajados',  (SELECT jsonb_array_length(j) FROM f),
        'nombres_no_bajados',
                       (SELECT coalesce(string_agg(DISTINCT x, ', '), '')
                          FROM f, jsonb_array_elements_text(f.j) AS x),
        'archivos',   (SELECT count(*) FROM d WHERE estado = 'parseado'),
        'pendientes', (SELECT count(*) FROM d WHERE estado = 'pendiente'),
        'fallados',   (SELECT count(*) FROM d WHERE estado = 'error'),
        'nombres_fallados',
                      (SELECT coalesce(string_agg(nombre_archivo, ', '
                                                  ORDER BY id), '')
                         FROM (SELECT id, nombre_archivo FROM d
                                WHERE estado = 'error' ORDER BY id LIMIT 5) t),
        'movimientos', (SELECT filas FROM m),
        'desde',       (SELECT desde  FROM m),
        'hasta',       (SELECT hasta  FROM m),
        'periodo',     (SELECT coalesce(periodo_es(desde, hasta), '') FROM m),
        'ultimo_en',   (SELECT max(creado_en) FROM d)
    );
$$;

COMMENT ON FUNCTION carga_resumen(bigint) IS
  'Contadores del panel de carga, leídos de documentos/movimientos y no de un '
  'acumulador. Cuenta lo que ENTRÓ, no lo que el plan deja analizar.';

-- =============================================================================
-- 4. Las tres caras del panel
-- =============================================================================
-- Es el mismo mensaje editándose, así que las tres comparten forma y teclado: si
-- el teclado cambiara de tamaño entre estados habría que cambiarlo también en
-- los nodos de n8n, que llevan la forma literal (ver la cabecera de
-- gen_wf_enviar.py). Los tres tienen dos filas de un botón.
--
-- `detalle` y `avisos` van en `crudas` porque traen HTML armado acá; el resto de
-- las variables las escapa resolver_plantilla como siempre (022).
INSERT INTO plantillas (clave, cuerpo, formato, variables, crudas, teclado) VALUES

('carga.panel',
 '📥 Llevo <b>{{archivos}}</b> {{palabra_archivo}} cargados.
{{detalle}}{{avisos}}
✅ <b>Cuando termines de mandarlos todos, tocá 📊 Analizar.</b>',
 'html',
 '["archivos","palabra_archivo","detalle","avisos"]'::jsonb,
 '["detalle","avisos"]'::jsonb,
 '[[{"texto":"📊 Analizar","dato":"/listo"}],
   [{"texto":"✖️ Cancelar","dato":"/cancelar"}]]'::jsonb),

('carga.panel_esperando',
 '⏳ <b>Esperando a que terminen de llegar tus archivos…</b>
{{detalle}}{{avisos}}
Arranco solo cuando dejen de entrar. No mandes nada más si ya terminaste.',
 'html',
 '["archivos","palabra_archivo","detalle","avisos"]'::jsonb,
 '["detalle","avisos"]'::jsonb,
 '[[{"texto":"✖️ Cancelar","dato":"/cancelar"}]]'::jsonb),

('carga.panel_analizando',
 '🔍 <b>Analizando {{archivos}} {{palabra_archivo}}…</b>
{{detalle}}
Te aviso acá mismo en cuanto esté.',
 'html',
 '["archivos","palabra_archivo","detalle"]'::jsonb,
 '["detalle"]'::jsonb,
 '[]'::jsonb)

ON CONFLICT (clave) DO UPDATE
  SET cuerpo = EXCLUDED.cuerpo, formato = EXCLUDED.formato,
      variables = EXCLUDED.variables, crudas = EXCLUDED.crudas,
      teclado = EXCLUDED.teclado, activo = true,
      version = plantillas.version + 1;

-- El panel NO se marca `reemplaza` (070): esa columna es para pantallas que se
-- editan cuando el usuario toca un botón, y el panel se edita cuando entra un
-- archivo, que no es un toque. Su message_id lo lleva `sesiones.panel_mensaje_id`
-- y lo usa wf_ingesta directamente.

-- =============================================================================
-- 5. El panel, resuelto y listo para mandar
-- =============================================================================
-- Devuelve texto y teclado ya resueltos más el chat y el mensaje a editar, para
-- que el workflow no tenga que saber nada: si `mensaje_id` viene NULL manda uno
-- nuevo y guarda el id; si viene, edita ese.
--
-- Se resuelve acá y no en wf_enviar porque el panel tiene teclado de forma FIJA
-- (dos filas de un botón, o una), y esa es justamente la única razón por la que
-- wf_enviar necesita su switch de siete nodos. Un panel de forma conocida se
-- manda con un nodo y se edita con otro.
CREATE OR REPLACE FUNCTION carga_panel(p_sesion_id bigint,
                                       p_modo text DEFAULT 'panel')
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_ses     record;
    v_res     jsonb := carga_resumen(p_sesion_id);
    v_clave   text;
    v_detalle text := '';
    v_avisos  text := '';
    v_n       int  := coalesce((v_res ->> 'archivos')::int, 0);
    v_mov     bigint := coalesce((v_res ->> 'movimientos')::bigint, 0);
    v_plant   record;
BEGIN
    -- El chat sale de `identidades` primero y de `usuarios` después: un usuario
    -- que entró por WhatsApp (044) no tiene telegram_chat_id, y uno de Telegram
    -- puede no tener identidad si viene de antes de la 044.
    SELECT s.*,
           coalesce(
             (SELECT (i.datos ->> 'chat_id')::bigint FROM identidades i
               WHERE i.usuario_id = s.usuario_id AND i.datos ? 'chat_id'
               ORDER BY i.vista_en DESC LIMIT 1),
             u.telegram_chat_id) AS chat_id
      INTO v_ses
    FROM sesiones s
    JOIN usuarios u ON u.id = s.usuario_id
    WHERE s.id = p_sesion_id;
    IF v_ses.id IS NULL OR v_ses.chat_id IS NULL THEN RETURN NULL; END IF;

    v_clave := CASE p_modo
                 WHEN 'esperando'  THEN 'carga.panel_esperando'
                 WHEN 'analizando' THEN 'carga.panel_analizando'
                 ELSE 'carga.panel' END;

    -- Detalle: solo lo que hay. Una línea "0 registros" en el primer archivo que
    -- todavía se está parseando asusta sin motivo.
    IF v_mov > 0 THEN
        v_detalle := format(E'\n📊 <b>%s</b> registros', miles(v_mov));
        IF coalesce(v_res ->> 'periodo', '') <> '' THEN
            v_detalle := v_detalle || format(E'\n📅 %s', v_res ->> 'periodo');
        END IF;
        v_detalle := v_detalle || E'\n';
    END IF;

    -- Avisos: los archivos que no se pudieron leer y los que quedaron guardados
    -- sin cargar. Van acá y no como mensaje aparte —que es lo que hacían hasta
    -- ahora— justamente para no volver a inundar el chat.
    IF coalesce((v_res ->> 'fallados')::int, 0) > 0 THEN
        v_avisos := v_avisos || format(E'\n⚠️ %s no los pude leer: %s',
                      (v_res ->> 'fallados'), (v_res ->> 'nombres_fallados'));
    END IF;
    IF coalesce((v_res ->> 'pendientes')::int, 0) > 0 THEN
        v_avisos := v_avisos || format(
          E'\n💾 %s guardados sin analizar todavía. No los perdés.',
          (v_res ->> 'pendientes'));
    END IF;
    -- El único caso en el que hay que pedir un reenvío, así que se pide claro y
    -- con el nombre: un archivo que no se pudo bajar no dejó ni rastro que
    -- recuperar después.
    IF coalesce((v_res ->> 'no_bajados')::int, 0) > 0 THEN
        v_avisos := v_avisos || format(
          E'\n❌ %s no los pude bajar del chat: %s\n   Volvé a mandar solo esos.',
          (v_res ->> 'no_bajados'), (v_res ->> 'nombres_no_bajados'));
    END IF;
    IF v_avisos <> '' THEN v_avisos := v_avisos || E'\n'; END IF;

    SELECT * INTO v_plant FROM resolver_plantilla(v_clave,
        jsonb_build_object(
          'archivos',        v_n::text,
          'palabra_archivo', CASE WHEN v_n = 1 THEN 'archivo' ELSE 'archivos' END,
          'detalle',         v_detalle,
          'avisos',          v_avisos),
        NULL) AS t(res);

    -- `canal` viaja para que el workflow sepa que en WhatsApp no puede editar ni
    -- fijar: allá el panel degrada a un mensaje más (mismo criterio que la 070).
    RETURN jsonb_build_object(
        'sesion_id',  p_sesion_id,
        'chat_id',    v_ses.chat_id,
        'canal',      canal_de_chat(v_ses.chat_id),
        'mensaje_id', v_ses.panel_mensaje_id,
        'modo',       p_modo,
        'texto',      v_plant.res ->> 'texto',
        'teclado',    v_plant.res -> 'teclado',
        'resumen',    v_res);
END;
$$;

COMMENT ON FUNCTION carga_panel(bigint, text) IS
  'El panel de carga resuelto: texto, teclado, chat y mensaje a editar. Si '
  'mensaje_id viene NULL el workflow manda uno nuevo y guarda el id con '
  'carga_panel_registrar.';

-- El workflow devuelve el message_id del panel recién mandado.
CREATE OR REPLACE FUNCTION carga_panel_registrar(p_sesion_id bigint,
                                                 p_mensaje_id bigint)
RETURNS void LANGUAGE sql AS $$
    UPDATE sesiones SET panel_mensaje_id = p_mensaje_id WHERE id = p_sesion_id;
$$;

-- =============================================================================
-- 6. Arrancar el análisis, una sola vez
-- =============================================================================
-- El UPDATE condicionado por `estado = 'recibiendo'` es la exclusión mutua: si
-- dos ejecuciones de wf_ingesta despiertan en el mismo segundo y las dos ven
-- silencio, solo una cambia la fila y solo esa crea la ejecución. La otra recibe
-- NULL y se calla. Sin esto el usuario recibiría dos informes.
CREATE OR REPLACE FUNCTION carga_arrancar(p_sesion_id bigint)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_ses     record;
    v_ejec_id bigint;
BEGIN
    UPDATE sesiones SET estado = 'procesando', paso = 'ejecutando'
    WHERE id = p_sesion_id AND estado = 'recibiendo' AND cerrada_en IS NULL
    RETURNING * INTO v_ses;

    IF v_ses.id IS NULL THEN RETURN NULL; END IF;

    INSERT INTO ejecuciones (sesion_id, negocio_id, servicio_codigo, estado)
    VALUES (v_ses.id, v_ses.negocio_id, v_ses.servicio_codigo, 'preparando')
    RETURNING id INTO v_ejec_id;

    RETURN v_ejec_id;
END;
$$;

-- ¿Hay con qué analizar? Es la compuerta que estaba dentro de router_h_recibiendo
-- (056) y sale acá porque ahora la consultan dos caminos: el botón y el debounce.
CREATE OR REPLACE FUNCTION carga_hay_con_que(p_sesion_id bigint)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM documentos
                    WHERE sesion_id = p_sesion_id AND estado = 'parseado')
        OR EXISTS (SELECT 1 FROM sesiones s
                    WHERE s.id = p_sesion_id
                      AND s.servicio_codigo = 'mercado_compras'
                      AND EXISTS (SELECT 1 FROM mov_visibles v
                                   WHERE v.negocio_id = s.negocio_id
                                     AND v.tipo = 'compra'));
$$;

COMMENT ON FUNCTION carga_hay_con_que(bigint) IS
  'Si la sesión tiene algo que analizar. mercado_compras puede correr sin '
  'archivos nuevos si el negocio ya tiene compras visibles (043).';

-- =============================================================================
-- 7. La decisión del debounce
-- =============================================================================
-- La llama wf_ingesta después de esperar, y el router cuando el usuario toca
-- Analizar. Contesta una de tres:
--
--   nada      no soy el último: entró un archivo después que yo y esa ejecución
--             más nueva es la que decide. Me callo.
--   panel     hubo silencio pero nadie pidió analizar: refresco el contador.
--   analizar  hubo silencio y el botón ya estaba tocado: arranco.
--
-- El caso que no existe es "descartar": ningún camino de esta función tira un
-- archivo. Esa es toda la migración.
CREATE OR REPLACE FUNCTION carga_evaluar(p_sesion_id bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_ses      record;
    v_res      jsonb;
    v_silencio int := coalesce(
        (parametro(NULL, 'carga_silencio_segundos'))::text::int, 10);
    v_ultimo   timestamptz;
    v_ejec_id  bigint;
BEGIN
    SELECT * INTO v_ses FROM sesiones WHERE id = p_sesion_id;
    IF v_ses.id IS NULL OR v_ses.cerrada_en IS NOT NULL THEN
        RETURN jsonb_build_object('accion', 'nada');
    END IF;

    v_res    := carga_resumen(p_sesion_id);
    v_ultimo := (v_res ->> 'ultimo_en')::timestamptz;

    -- Todavía están llegando: el que entre después se encarga.
    IF v_ultimo IS NOT NULL AND now() - v_ultimo < make_interval(secs => v_silencio) THEN
        RETURN jsonb_build_object('accion', 'nada');
    END IF;

    -- Silencio, y el botón ya estaba tocado.
    IF v_ses.analisis_pedido_en IS NOT NULL AND v_ses.estado = 'recibiendo' THEN
        IF NOT carga_hay_con_que(p_sesion_id) THEN
            RETURN jsonb_build_object('accion', 'panel',
                     'panel', carga_panel(p_sesion_id, 'panel'));
        END IF;
        v_ejec_id := carga_arrancar(p_sesion_id);
        IF v_ejec_id IS NULL THEN               -- otro llegó primero
            RETURN jsonb_build_object('accion', 'nada');
        END IF;
        RETURN jsonb_build_object('accion', 'analizar', 'ejecucion_id', v_ejec_id,
                 'panel', carga_panel(p_sesion_id, 'analizando'));
    END IF;

    -- Silencio y nadie pidió nada: solo refresco el contador.
    IF v_ses.estado = 'recibiendo' THEN
        RETURN jsonb_build_object('accion', 'panel',
                 'panel', carga_panel(p_sesion_id, 'panel'));
    END IF;

    RETURN jsonb_build_object('accion', 'nada');
END;
$$;

COMMENT ON FUNCTION carga_evaluar(bigint) IS
  'Qué hacer al terminar la espera de wf_ingesta: nada, refrescar el panel o '
  'arrancar el análisis. Ningún camino descarta un archivo.';

-- =============================================================================
-- 8. El router: el botón agenda, no dispara
-- =============================================================================
CREATE OR REPLACE FUNCTION router_h_recibiendo(p_ctx jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_chat_id    bigint  := (p_ctx ->> 'chat_id')::bigint;
    v_cmd        text    := p_ctx ->> 'cmd';
    v_tiene_doc  boolean := (p_ctx ->> 'tiene_doc')::boolean;
    v_ses_id     bigint  := (p_ctx ->> 'sesion_id')::bigint;
    v_ses_srv    text    := p_ctx ->> 'sesion_servicio';
    v_ev         jsonb;
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

    -- /todos y /faltan quedaron sin uso: el panel dice todo el tiempo lo que la
    -- pregunta preguntaba una vez. Se siguen aceptando porque puede haber un
    -- teclado viejo en el chat de alguien, y contestan con el panel.
    IF v_cmd IN ('/todos','/faltan') THEN
        RETURN jsonb_build_object('chat_id', v_chat_id, 'respuestas', '[]'::jsonb,
                 'acciones', jsonb_build_array(jsonb_build_object(
                   'tipo','panel','sesion_id', v_ses_id)));
    END IF;

    IF v_cmd IN ('/listo','/analizar','/fin') THEN
        IF NOT carga_hay_con_que(v_ses_id) THEN
            RETURN router_respuesta(v_chat_id, 'sistema.sin_documentos');
        END IF;

        -- El botón deja la marca y NO arranca. Si ya hubo silencio suficiente,
        -- carga_evaluar arranca en la misma llamada; si todavía están llegando
        -- archivos, el panel pasa a "esperando" y arranca el debounce del último
        -- que entre. Esta es la línea que perdió los 38 archivos.
        UPDATE sesiones SET analisis_pedido_en = now() WHERE id = v_ses_id;

        v_ev := carga_evaluar(v_ses_id);
        IF v_ev ->> 'accion' = 'analizar' THEN
            RETURN jsonb_build_object('chat_id', v_chat_id, 'respuestas', '[]'::jsonb,
                     'acciones', jsonb_build_array(
                       jsonb_build_object('tipo','panel','sesion_id', v_ses_id,
                                          'modo','analizando'),
                       jsonb_build_object('tipo','ejecutar',
                                          'ejecucion_id', (v_ev ->> 'ejecucion_id')::bigint)));
        END IF;

        RETURN jsonb_build_object('chat_id', v_chat_id, 'respuestas', '[]'::jsonb,
                 'acciones', jsonb_build_array(jsonb_build_object(
                   'tipo','panel','sesion_id', v_ses_id, 'modo','esperando')));
    END IF;

    RETURN router_respuesta(v_chat_id, 'sistema.esperando_listo');
END;
$$;

-- =============================================================================
-- 9. El despachador: un documento nunca se contesta y se tira
-- =============================================================================
-- Único cambio respecto de la 056, y es el que arregla el bug: la compuerta de
-- 'procesando' sigue existiendo —no se disparan dos corridas— pero deja pasar el
-- documento. El archivo entra a la base mientras el informe se está armando; el
-- panel lo cuenta y la 072 decide si alcanza para rehacer el informe.
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

    -- Ya se está ejecutando: nada de disparar una segunda corrida, PERO el
    -- archivo entra igual. Ver la cabecera de esta migración.
    IF v_sesion.estado = 'procesando' THEN
        IF coalesce((v_ctx ->> 'tiene_doc')::boolean, false) THEN
            RETURN router_respuesta((v_ctx ->> 'chat_id')::bigint,
                     NULL, NULL, NULL,
                     jsonb_build_array(jsonb_build_object(
                       'tipo','ingerir','sesion_id', v_sesion.id)));
        END IF;
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

-- =============================================================================
-- 10. El mensaje que pide los archivos deja de llevar el botón
-- =============================================================================
-- La 049 puso ahí el botón porque era el único mensaje que quedaba fijo arriba
-- de la carga. Ahora el panel es ese lugar y encima está fijado, así que el
-- botón acá solo serviría para arrancar un análisis sin haber mandado nada.
-- El texto también deja de mandar al usuario a "volver a este mensaje".
UPDATE plantillas SET cuerpo =
'Listo: <b>{{servicio}}</b>.

Mandame los archivos de <b>facturación</b> de tu negocio: las <b>ventas</b> y las <b>compras</b>. De dónde salgan no me importa —lo que exporte tu sistema, lo que te pase el contador, un Excel que llevés a mano— y tampoco cómo se llamen las columnas: yo los leo.

📎 Me sirven archivos {{formatos}}.

📅 <b>Cuánta historia mandarme:</b> con <b>3 meses</b> ya sale un análisis serio. Entre más me mandes, mejor: las tendencias de costo y lo que rota lento no se ven en dos semanas.

Mandalos todos de una: los voy contando en un mensaje que dejo fijado arriba, y ahí mismo vas a tener el botón para analizar cuando termines.',
  variables = '["servicio","formatos"]'::jsonb,
  teclado = '[[{"texto":"✖️ Cancelar","dato":"/cancelar"}]]'::jsonb,
  version = version + 1
WHERE clave = 'sistema.pedir_archivos';

-- La plantilla de "ya en curso" deja de sugerir que todo está bien: ahora solo
-- la ve quien escribe texto durante una corrida, no quien manda un archivo.
UPDATE plantillas SET cuerpo =
'⏳ Ya estoy trabajando en tu informe. Aguantame un momento, te aviso acá mismo.

Si me mandás archivos ahora los guardo igual y te aviso cuando termine.',
  version = version + 1
WHERE clave = 'ejecucion.ya_en_curso';

NOTIFY pgrst, 'reload schema';
