-- 057_limpieza.sql — sacar lo muerto de en medio y cerrar la fuga de datos que
-- nadie estaba mirando.
--
-- A5 cierra la Fase A'. Son dos cosas distintas en una migración porque las dos
-- son deuda acumulada y ninguna justifica una ventana propia:
--
--   PARTE I  — bajas: objetos vivos que ya no responden ninguna pregunta.
--   PARTE II — el `periodo` que la 051 borró sin querer (H5 en acción).
--   PARTE III— los textos de usuario que quedaron dentro de nodos de n8n.
--   PARTE IV — matching: C3, que es lo único de acá que BLOQUEA la Fase C.
--
-- Sobre las bajas, la regla del proyecto: las migraciones son un log histórico y
-- NO se editan. Dar de baja significa borrar el objeto vivo con una migración
-- nueva, nunca tocar la que lo creó.
--
-- =============================================================================
-- PARTE I — Bajas
-- =============================================================================

-- 1. servicios.pasos ---------------------------------------------------------
-- "Guion de intake, resuelto en Postgres" (001). Letra muerta desde la 012: el
-- router nunca lo leyó, y la 024 terminó de sacarle sentido al dejar de pedir
-- pasos que el sistema puede resolver solo. Verificado: cero lecturas en db/,
-- bin/ y portal/.
ALTER TABLE servicios DROP COLUMN IF EXISTS pasos;

-- 2. plantillas_pdf + Gotenberg ----------------------------------------------
-- Muertos desde la 020, cuando el informe pasó a entregarse como texto en el
-- chat. Se habían dejado "para poder volver atrás"; hace ocho migraciones que
-- nadie vuelve. `ejecucion_preparar` todavía consultaba la tabla y publicaba
-- `plantilla_pdf` en su respuesta, y el generador vigente de wf_ejecutar ya no
-- lo lee: era trabajo por nada en cada corrida.
--
-- El contenedor sale del compose en el mismo commit (docs/GUIA_TECNICA §2).
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
            'max_tokens', v_prompt.max_tokens)
    );
END;
$$;

DROP TABLE IF EXISTS plantillas_pdf;

-- 3. parametros.rotacion_baja_dias -------------------------------------------
-- Sembrado en la 003 y nunca leído por nadie. La 047 introdujo
-- `rotacion_lenta_dias`, que es el umbral que de verdad decide "plata quieta";
-- este quedó como un parámetro fantasma que un operador podía cambiar creyendo
-- que calibraba algo.
DELETE FROM parametros WHERE negocio_id IS NULL AND clave = 'rotacion_baja_dias';

-- 4. teclado_servicios() -----------------------------------------------------
-- Segundo menú coexistiendo con el de módulos, con textos distintos para los
-- mismos servicios. Es de antes de la 045: lista TODOS los servicios de archivos
-- en plano y cierra con "✖️ Cancelar", mientras que `teclado_modulo` lista los
-- del módulo y cierra con "❓ Cómo funciona" y "⬅️ Volver". Dos formas de ver lo
-- mismo, y una sola de mantenerlas sincronizadas: a mano.
--
-- La unificación no es "usar siempre teclado_modulo": con varios módulos, un
-- listado plano de todos los servicios sería el menú equivocado. La regla es la
-- del diseño de la 045/046 —módulo primero— con el atajo obvio cuando hay uno
-- solo, que es el caso hoy y sería absurdo mostrar como un menú de un botón.
CREATE OR REPLACE FUNCTION teclado_intake() RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN (SELECT count(*) FROM modulos WHERE activo) = 1
                THEN teclado_modulo((SELECT codigo FROM modulos WHERE activo))
                ELSE teclado_modulos()
           END;
$$;

COMMENT ON FUNCTION teclado_intake() IS
  'Teclado de "¿qué querés hacer?". Con un solo módulo activo entra directo a '
  'sus servicios; con varios muestra los módulos. Reemplaza a teclado_servicios '
  '(023/030), que era un segundo menú con textos propios para los mismos '
  'servicios.';

-- Los tres llamadores son handlers del router (056). Se reemplaza cada uno
-- entero, que es exactamente lo que A4 vino a hacer barato: antes esto obligaba
-- a pegar las 356 líneas del router.

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
                 '{}'::jsonb, teclado_intake());
    END IF;

    -- ---- Servicio elegido desde el menú (045) ------------------------------
    IF v_cmd = 'svc' AND (v_ses_id IS NULL OR v_ses_estado = 'intake') THEN
        SELECT * INTO v_servicio FROM servicios
        WHERE activo AND entrada = 'archivos' AND codigo = v_svc;

        IF v_servicio.codigo IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.servicio_no_reconocido',
                     '{}'::jsonb, teclado_intake());
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
                 '{}'::jsonb, teclado_intake());
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
                 '{}'::jsonb, teclado_intake());
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


DROP FUNCTION IF EXISTS teclado_servicios();

-- =============================================================================
-- PARTE II — El `periodo` que se perdió
-- =============================================================================
-- Es H5 en acción, y por eso vale la pena contarlo entero: la 046 agregó a
-- `ingesta_resumen_sesion` el periodo de facturación cubierto por los archivos,
-- con una justificación explícita —"es el momento de mandar más, no después de
-- ver un informe flojo"—. La 051 tenía que tocar OTRA cosa de la misma función
-- (el aviso del plan free), pegó una copia basada en una versión anterior, y el
-- periodo desapareció sin que nadie lo mencionara. La 053 heredó esa copia.
--
-- Resultado: durante tres migraciones, un negocio que subía dos semanas de
-- ventas no se enteraba de que eran dos semanas hasta ver el informe. Se
-- restaura el bloque tal como lo escribió la 046, sumado a lo que la 053 agregó.
-- Desde la 056 esto ya no puede volver a pasar por el router; para esta función
-- el riesgo sigue vivo (ver la deuda anotada en el ROADMAP).
CREATE OR REPLACE FUNCTION ingesta_resumen_sesion(p_sesion_id bigint)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    WITH docs AS (
        SELECT d.id, d.nombre_archivo, d.filas_fuera_de_plan,
               (SELECT count(*) FROM movimientos m WHERE m.documento_id = d.id) AS filas,
               (SELECT round(coalesce(sum(m.valor_total), 0))
                  FROM movimientos m WHERE m.documento_id = d.id)               AS total
        FROM documentos d
        WHERE d.sesion_id = p_sesion_id AND d.estado = 'parseado'
    ),
    fuera AS (SELECT coalesce(sum(filas_fuera_de_plan), 0)::int AS n FROM docs),
    -- >>> 046, restaurado por 057. Mira `movimientos` y no `mov_visibles` a
    -- propósito: informa qué trajo el archivo, que es lo honesto — el mismo
    -- criterio por el que la 053 dejó esta función fuera del repunte a
    -- `mov_visibles`. Lo que el plan todavía no analiza lo dice `aviso_plan`.
    rango AS (
        SELECT min(m.fecha) AS desde, max(m.fecha) AS hasta
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
                     ELSE '' END,
        -- >>> 053: lo que el plan gratuito todavía no analiza. Se guardó todo.
        'aviso_plan', CASE WHEN (SELECT n FROM fuera) > 0
                     THEN format(E'\n\n🎁 Guardé %s registros más viejos que %s meses, pero todavía no los analizo: el plan gratuito cubre esa ventana. Están ahí esperando —si ampliás el plan entran al análisis solos, sin volver a mandarme nada—. Mirá /plan.',
                                 (SELECT n FROM fuera),
                                 coalesce((parametro(NULL, 'plan_free_meses_historia'))::text, '3'))
                     ELSE '' END
    );
$$;

-- La plantilla también había perdido el hueco. Sin esto, la función calcula el
-- periodo y nadie lo muestra.
UPDATE plantillas
   SET cuerpo = 'Esto fue lo que cargué:

{{detalle}}

Total: {{total}}{{periodo}}{{aviso_nit}}{{aviso_plan}}'
 WHERE clave = 'ingesta.resumen_sesion';

-- =============================================================================
-- PARTE III — Los textos de usuario salen de los nodos de n8n
-- =============================================================================
-- `docs/GUIA_TECNICA` dice que el comportamiento vive en filas, no en nodos, y
-- las ramas de error de `wf_ingesta` lo contradecían: "no reconocí el formato",
-- "no pude descargarlo del chat", "se me cayó guardándolo" estaban escritas
-- dentro de nodos Code. Cambiarle una palabra a cualquiera de esas frases
-- obligaba a regenerar y reimportar un workflow.
--
-- No hace falta mover lógica para arreglarlo: cada rama ya elegía una plantilla.
-- Lo que hacía mal era pasar el TEXTO del motivo como variable. Ahora cada rama
-- nombra SU plantilla y solo pasa datos (el nombre del archivo, y el detalle
-- técnico cuando la base lo escribió). Los generadores cambian en el mismo
-- commit; acá quedan las palabras.
--
-- `ingesta.error_archivo` se conserva sin tocar: ahí el motivo lo escribe
-- `ingesta_registrar_documento`, o sea que ya venía de la base. Eso es un dato,
-- no copy.
INSERT INTO plantillas (clave, cuerpo, formato) VALUES
('ingesta.error_no_soportado',
'❌ No pude usar <b>{{nombre_archivo}}</b>.

No reconocí el formato de ese archivo.{{detalle}}

Mandámelo en Excel, CSV, o como XML de la DIAN. El resto de los archivos sigue en pie.',
 'html'),
('ingesta.error_descarga',
'❌ No pude bajar <b>{{nombre_archivo}}</b> del chat.

Puede haber sido un problema momentáneo: volvé a mandarlo y sigo desde ahí.',
 'html'),
('ingesta.error_guardando',
'❌ Se me cayó guardando <b>{{nombre_archivo}}</b>.{{detalle}}

No es culpa tuya ni del archivo. Volvé a mandarlo en un rato; si sigue pasando, avisame.',
 'html'),
-- El aviso al admin de wf_error se armaba concatenando SQL en el nodo, sin
-- pasar por plantillas: era el único mensaje del sistema que no se podía
-- cambiar sin tocar Python.
('falla.aviso_admin',
'⚠️ Falla en <b>{{workflow}}</b> ({{tipo}})

<code>{{mensaje}}</code>',
 'html')
ON CONFLICT (clave) DO UPDATE
  SET cuerpo = EXCLUDED.cuerpo, formato = EXCLUDED.formato, activo = true;

-- =============================================================================
-- PARTE IV — Matching: lo único de A5 que bloquea la Fase C
-- =============================================================================
-- C3: `match_confirmar_alias` existe desde la 005 y NO TIENE UN SOLO LLAMADOR.
-- Verificado en db/, bin/ y portal/. Los alias con `origen='pendiente'` se
-- acumulan sin salida, y un movimiento sin `producto_id` no entra a ningún
-- cálculo: no tiene margen, no tiene rotación, no entra al Pareto, no aparece
-- en ninguna recomendación. Es plata que se pierde de vista en silencio.
--
-- Y `/matching` reportaba el problema de la peor manera posible: "85% resuelto"
-- suena bien, pero el 15% restante puede ser el 60% de la facturación si lo que
-- no se resolvió son los productos que más se venden. Un porcentaje de aliases
-- no dice cuánta plata queda afuera.
--
-- Esta parte no inventa nada: expone lo que ya estaba construido.

-- 1. La vista de calidad aprende a hablar de dinero ---------------------------
-- Cambia la base de `alias` a `negocios`: antes, un negocio con movimientos sin
-- resolver pero sin ninguna fila en `alias` simplemente no aparecía en el
-- reporte. El dinero se mide sobre `mov_visibles` —no sobre `movimientos`—
-- porque la pregunta es cuánto queda fuera de LOS CÁLCULOS, y los cálculos leen
-- la ventana visible del plan (053).
CREATE OR REPLACE VIEW v_calidad_matching AS
SELECT n.id                                                    AS negocio_id,
       count(a.id)                                             AS aliases,
       count(a.id) FILTER (WHERE a.producto_id IS NOT NULL)    AS resueltos,
       count(a.id) FILTER (WHERE a.producto_id IS NULL)        AS pendientes,
       count(a.id) FILTER (WHERE a.origen = 'trigram')         AS por_trigram,
       count(a.id) FILTER (WHERE a.origen = 'manual')          AS confirmados_manual,
       round(100.0 * count(a.id) FILTER (WHERE a.producto_id IS NOT NULL)
             / nullif(count(a.id), 0), 1)                      AS pct_resuelto,
       -- >>> 057: lo que de verdad importa. Cuántos movimientos y cuánta plata
       -- quedan fuera de todo cálculo por no tener producto resuelto.
       m.movs_sin_producto,
       m.dinero_sin_producto,
       m.pct_dinero_fuera
FROM negocios n
LEFT JOIN alias a ON a.negocio_id = n.id
CROSS JOIN LATERAL (
    SELECT count(*) FILTER (WHERE v.producto_id IS NULL)                 AS movs_sin_producto,
           round(coalesce(sum(v.valor_total) FILTER (WHERE v.producto_id IS NULL), 0)) AS dinero_sin_producto,
           round(100.0 * coalesce(sum(v.valor_total) FILTER (WHERE v.producto_id IS NULL), 0)
                 / nullif(sum(v.valor_total), 0), 1)                     AS pct_dinero_fuera
    FROM mov_visibles v WHERE v.negocio_id = n.id
) m
GROUP BY n.id, m.movs_sin_producto, m.dinero_sin_producto, m.pct_dinero_fuera;

-- 2. Los pendientes, con su mejor candidato ----------------------------------
-- Reusa `match_resolver_producto`? No: esa función escribe. Acá solo se mira,
-- con el mismo trigram sobre el que ya hay un índice (005).
CREATE OR REPLACE FUNCTION alias_pendientes(p_negocio_id bigint,
                                            p_limite int DEFAULT 50)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'alias_id',   x.id,
             'texto',      x.texto_norm,
             'movimientos',x.movs,
             'dinero',     x.dinero,
             'candidato_id',     x.candidato_id,
             'candidato_nombre', x.candidato_nombre,
             'similitud',        x.similitud)
             ORDER BY x.dinero DESC, x.movs DESC), '[]'::jsonb)
    FROM (
        SELECT a.id, a.texto_norm,
               (SELECT count(*) FROM mov_visibles m
                 WHERE m.negocio_id = a.negocio_id AND m.producto_id IS NULL
                   AND (m.alias_id = a.id
                        OR norm_texto(m.raw ->> 'descripcion') = a.texto_norm
                        OR norm_texto(m.raw ->> 'producto')    = a.texto_norm)) AS movs,
               (SELECT round(coalesce(sum(m.valor_total), 0)) FROM mov_visibles m
                 WHERE m.negocio_id = a.negocio_id AND m.producto_id IS NULL
                   AND (m.alias_id = a.id
                        OR norm_texto(m.raw ->> 'descripcion') = a.texto_norm
                        OR norm_texto(m.raw ->> 'producto')    = a.texto_norm)) AS dinero,
               c.id AS candidato_id, c.nombre_canonico AS candidato_nombre,
               round(c.sim::numeric, 3) AS similitud
        FROM alias a
        LEFT JOIN LATERAL (
            SELECT p.id, p.nombre_canonico,
                   similarity(norm_texto(p.nombre_canonico), a.texto_norm) AS sim
            FROM productos p
            WHERE p.negocio_id = a.negocio_id
            ORDER BY sim DESC LIMIT 1
        ) c ON true
        WHERE a.negocio_id = p_negocio_id AND a.producto_id IS NULL
        ORDER BY 4 DESC NULLS LAST
        LIMIT p_limite
    ) x;
$$;

-- 3. /matching y /pendientes -------------------------------------------------
CREATE OR REPLACE FUNCTION admin_reporte(p_cmd text)
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

    -- >>> 057: el porcentaje de aliases no dice cuánta plata queda afuera.
    -- Ahora dice las dos cosas, y el dinero va primero porque es el que decide
    -- si hay que hacer algo.
    ELSIF p_cmd = '/matching' THEN
        SELECT coalesce(string_agg(format(
                 'negocio %s: $%s fuera de los cálculos (%s%% del movimiento, %s movs) · aliases %s%% resuelto, %s pendientes',
                 negocio_id, miles(dinero_sin_producto), coalesce(pct_dinero_fuera, 0),
                 movs_sin_producto, coalesce(pct_resuelto, 0), pendientes), E'\n'), 'sin datos')
        INTO v FROM v_calidad_matching;
        RETURN '🔗 *Calidad de matching*' || E'\n' || v
               || E'\n\nPara resolverlos: /pendientes, o la pestaña Ventas del /portal.';

    -- >>> 057: la salida que `match_confirmar_alias` no tenía (C3). Solo lista:
    -- confirmar necesita elegir entre productos, y eso se hace en el portal.
    ELSIF p_cmd = '/pendientes' THEN
        SELECT coalesce(string_agg(format('negocio %s · %s%s  [%s movs, $%s]',
                 c.negocio_id, e.texto,
                 CASE WHEN e.candidato_nombre IS NULL THEN ''
                      ELSE format(' → ¿%s? (%s)', e.candidato_nombre, e.similitud) END,
                 e.movimientos, miles(e.dinero)), E'\n'), 'nada pendiente')
        INTO v
        FROM v_calidad_matching c,
             LATERAL jsonb_to_recordset(alias_pendientes(c.negocio_id, 10))
               AS e(texto text, movimientos bigint, dinero numeric,
                    candidato_nombre text, similitud numeric)
        WHERE c.pendientes > 0;
        RETURN '🧩 *Productos sin resolver*' || E'\n' || coalesce(v, 'nada pendiente')
               || E'\n\nSe confirman en la pestaña Ventas del /portal.';

    ELSE
        RETURN '📋 Comandos: /salud /embudo /fallas /consumo /matching /pendientes';
    END IF;
END;
$$;


-- `/pendientes` es un comando de admin: hay que declararlo en el handler que
-- decide quién puede correr qué. Es un CREATE OR REPLACE de veinte líneas
-- gracias a la 056; antes era una copia del router entero.
CREATE OR REPLACE FUNCTION router_h_admin(p_ctx jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_chat_id bigint := (p_ctx ->> 'chat_id')::bigint;
    v_cmd     text   := p_ctx ->> 'cmd';
BEGIN
    IF v_cmd NOT IN ('/salud','/embudo','/fallas','/consumo','/matching',
                     '/pendientes','/admin') THEN
        RETURN NULL;
    END IF;
    IF (p_ctx ->> 'rol') IS DISTINCT FROM 'admin' THEN
        RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
    END IF;
    RETURN router_respuesta(v_chat_id, admin_reporte(v_cmd));
END;
$$;

-- 4. El portal resuelve los pendientes ---------------------------------------
-- Acá es donde C3 se cierra de verdad: `match_confirmar_alias` (005) pasa a
-- tener un llamador. La RPC no reimplementa nada — valida que el alias y el
-- producto sean del negocio de la sesión y delega.
CREATE OR REPLACE FUNCTION portal_alias_pendientes(p_limite int DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    RETURN jsonb_build_object(
      'pendientes', alias_pendientes(v_negocio, p_limite),
      'resumen', (SELECT jsonb_build_object(
                    'movs_sin_producto',   movs_sin_producto,
                    'dinero_sin_producto', dinero_sin_producto,
                    'pct_dinero_fuera',    coalesce(pct_dinero_fuera, 0))
                  FROM v_calidad_matching WHERE negocio_id = v_negocio));
END;
$$;

CREATE OR REPLACE FUNCTION portal_alias_confirmar(p_alias_id bigint,
                                                  p_producto_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    -- Las dos puntas tienen que ser del negocio de la sesión. Sin esto, la RPC
    -- sería una forma de mover productos entre negocios.
    IF NOT EXISTS (SELECT 1 FROM alias
                    WHERE id = p_alias_id AND negocio_id = v_negocio
                      AND producto_id IS NULL)
       OR NOT EXISTS (SELECT 1 FROM productos
                       WHERE id = p_producto_id AND negocio_id = v_negocio) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_encontrado');
    END IF;

    PERFORM match_confirmar_alias(p_alias_id, p_producto_id);

    RETURN jsonb_build_object('ok', true,
      'movimientos', (SELECT count(*) FROM movimientos
                       WHERE negocio_id = v_negocio AND alias_id = p_alias_id));
END;
$$;

GRANT EXECUTE ON FUNCTION portal_alias_pendientes(int)             TO portal_usuario;
GRANT EXECUTE ON FUNCTION portal_alias_confirmar(bigint, bigint)   TO portal_usuario;

NOTIFY pgrst, 'reload schema';
