-- 051_consentimiento_y_plan_free.sql — el permiso se pide donde se entienden
-- sus consecuencias, la IA se declara, y el plan gratis tiene un límite real.
--
-- Tres cosas, todas de cara al usuario:
--
-- 1. CONSENTIMIENTO EN EL MOMENTO CORRECTO. Antes, el primer mensaje que no
--    fuera /start chocaba contra "necesito tu permiso para tratar los datos de
--    tu negocio": una frase sola, antes de que el usuario supiera siquiera qué
--    hace el bot, y al aceptar volvía a la bienvenida perdiendo el paso que
--    estaba dando. Ahora el menú ("Esto es lo que puedo hacer por ahora") se
--    puede mirar sin autorizar nada, y el permiso se pide al ELEGIR una opción
--    —que es cuando de verdad se van a entregar datos—. El botón se lleva
--    puesto lo que el usuario tocó ('acepto:svc:ventas_compras'), así que al
--    aceptar el proceso sigue solo, sin repetir el clic.
--
-- 2. LA IA SE DECLARA. Todo lo que devuelve el asistente sale de un análisis
--    hecho con IA sobre los archivos del negocio: puede equivocarse, no es
--    contabilidad certificada y no reemplaza al contador. Eso va en el
--    consentimiento (antes de aceptar) y al pie de cada informe entregado
--    (cuando se está leyendo el resultado). En los dos lados, visible.
--
-- 3. PLAN FREE = 3 MESES DE HISTORIA. Hasta ahora "free" solo limitaba tokens.
--    El límite de historia se aplica en un trigger sobre `movimientos`: cubre
--    todos los caminos de carga (XML DIAN, tabular, facturas, cartera) y los
--    que se agreguen después, sin repetir la regla en cada uno. Lo que queda
--    fuera de ventana NO se guarda, y se le dice al usuario cuántas filas
--    fueron y por qué.

-- =============================================================================
-- 1. Plan free: la ventana de historia
-- =============================================================================
DELETE FROM parametros WHERE negocio_id IS NULL AND clave = 'plan_free_meses_historia';
INSERT INTO parametros (negocio_id, clave, valor)
VALUES (NULL, 'plan_free_meses_historia', '3'::jsonb);

-- Desde qué fecha se le aceptan movimientos a este negocio. NULL = sin límite
-- (plan pago). Se calcula por mes calendario completo: con 3 meses, el 28 de
-- julio acepta desde el 1 de mayo. Cortar por "hace 90 días exactos" partiría
-- el mes más viejo por la mitad y el informe mostraría un mes incompleto.
CREATE OR REPLACE FUNCTION plan_desde(p_negocio_id bigint)
RETURNS date LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN coalesce((SELECT plan FROM negocios WHERE id = p_negocio_id), 'free') <> 'free'
          THEN NULL
        ELSE date_trunc('month', current_date)::date
             - (coalesce((parametro(p_negocio_id, 'plan_free_meses_historia'))::text::int, 3) - 1)
               * interval '1 month'
    END::date;
$$;

-- Cuántas filas se quedaron por fuera. Va en `documentos` porque el aviso se da
-- por archivo y por sesión, y el documento es lo que sobrevive a las dos.
ALTER TABLE documentos
  ADD COLUMN IF NOT EXISTS filas_fuera_de_plan int NOT NULL DEFAULT 0;

-- El filtro. BEFORE INSERT y por fila: descartar acá es la única forma de que
-- ningún camino de ingesta se salte la regla por olvido. Las filas sin fecha no
-- se tocan (ya las mide la compuerta de la 017); solo se descarta lo que tiene
-- fecha comprobadamente vieja.
CREATE OR REPLACE FUNCTION movimientos_limite_plan() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_desde date;
BEGIN
    IF NEW.fecha IS NULL THEN RETURN NEW; END IF;

    v_desde := plan_desde(NEW.negocio_id);
    IF v_desde IS NULL OR NEW.fecha >= v_desde THEN RETURN NEW; END IF;

    IF NEW.documento_id IS NOT NULL THEN
        UPDATE documentos SET filas_fuera_de_plan = filas_fuera_de_plan + 1
        WHERE id = NEW.documento_id;
    END IF;
    RETURN NULL;   -- fuera de la ventana del plan: no se guarda
END;
$$;

DROP TRIGGER IF EXISTS trg_movimientos_limite_plan ON movimientos;
CREATE TRIGGER trg_movimientos_limite_plan
    BEFORE INSERT ON movimientos
    FOR EACH ROW EXECUTE FUNCTION movimientos_limite_plan();

-- =============================================================================
-- 2. El consentimiento
-- =============================================================================
-- Describe al ASISTENTE, no a la base de datos que tiene debajo: qué le va a
-- resolver al dueño en su día a día. Y dice, sin letra chica, que todo eso lo
-- produce una IA.
INSERT INTO plantillas (clave, cuerpo, formato, variables, teclado) VALUES
('sistema.consentimiento',
'Antes de arrancar, dos cosas claras. 👇

<b>Qué hago por vos</b>
Soy tu asistente de negocio. No soy un programa donde tenés que meter datos: me mandás lo que ya tenés y yo trabajo con eso.

• 📊 <b>Te leo los números</b> y te digo qué te deja plata, qué te la está quitando y a qué producto le subió el costo.
• 💰 <b>Cobranzas:</b> llevo quién te debe, cuánto y desde cuándo, y te aviso a quién toca cobrarle esta semana.
• ⏰ <b>Recordatorios:</b> lo que hay que pagar, pedir o revisar, en el momento en que sirve acordarse.
• 🔔 <b>Alertas:</b> se te está agotando algo que rota, un proveedor te subió el precio, un cliente se atrasó más de lo normal.
• 🧭 <b>Recomendaciones:</b> en qué conviene gastar primero y qué decisión tiene más efecto esta semana.
• 💬 <b>Preguntame lo que sea</b> de tu negocio y te contesto con tus propios datos.

<b>⚠️ Importante: esto lo hace una inteligencia artificial</b>
Todo lo que te entrego —informes, cifras, alertas y recomendaciones— es el <b>resultado de un análisis hecho con IA</b> sobre los archivos que vos me mandes. <b>Puede equivocarse.</b> No es contabilidad certificada ni asesoría legal, financiera o tributaria, y <b>no reemplaza a tu contador</b>. Antes de tomar una decisión de plata, contrastá con tus soportes. Las decisiones de tu negocio son tuyas.

<b>🔐 Tus datos</b>
Los uso solo para trabajar para vos: quedan guardados en tu negocio, no se comparten con nadie ni se usan para otra cosa, y los borro el día que me lo pidas. Escribí /privacidad para el detalle.

<b>🎁 Plan gratuito</b>
Podés cargar hasta <b>{{meses}} meses</b> de historia. Lo más viejo que eso no lo guardo. Para trabajar con toda tu historia y tener las alertas y los recordatorios andando todo el mes, se necesita el servicio completo (/plan).

¿Arrancamos?',
 'html', '["meses"]'::jsonb, '[]'::jsonb)
ON CONFLICT (clave) DO UPDATE
  SET cuerpo = EXCLUDED.cuerpo, formato = EXCLUDED.formato,
      variables = EXCLUDED.variables, teclado = EXCLUDED.teclado,
      version = plantillas.version + 1;

DELETE FROM plantillas WHERE clave = 'sistema.no_autorizado';

-- El botón carga el paso que lo disparó, para retomarlo al aceptar. El límite
-- de 64 bytes del callback_data de Telegram es real: un texto largo (una
-- pregunta libre, por ejemplo) no cabe, y ahí se acepta sin contexto y se
-- vuelve a la bienvenida. Los botones del menú ('svc:...') caben de sobra.
CREATE OR REPLACE FUNCTION teclado_consentimiento(p_contexto text DEFAULT '')
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_array(
      jsonb_build_array(jsonb_build_object(
        'texto', '✅ Acepto y continúo',
        'dato',  'acepto:' || CASE WHEN octet_length(coalesce(p_contexto,'')) <= 50
                                   THEN coalesce(p_contexto,'') ELSE '' END)),
      jsonb_build_array(jsonb_build_object(
        'texto', '🔐 Cómo trato tus datos', 'dato', '/privacidad')));
$$;

-- =============================================================================
-- 3. La advertencia de IA al pie del informe
-- =============================================================================
-- El consentimiento se lee una vez, en el minuto cero. El informe se lee cada
-- vez que se entrega y es el momento en que alguien puede tomar una decisión de
-- plata con estos números: la advertencia tiene que estar ahí también.
UPDATE plantillas SET cuerpo =
'{{texto}}

——————————
⚠️ <b>Análisis hecho con IA.</b> Estas cifras y recomendaciones salen de leer con inteligencia artificial los archivos que me mandaste: <b>pueden tener errores</b>. No son contabilidad certificada ni asesoría financiera o tributaria, y no reemplazan a tu contador. Antes de mover plata, contrastá con tus soportes.',
  version = version + 1
WHERE clave = 'ejecucion.entregada';

-- =============================================================================
-- 4. "Esto es lo que puedo hacer por ahora": el asistente, no el ERP
-- =============================================================================
UPDATE modulos SET
    titular =
'Esto es lo que puedo hacer por ahora. Elegí por dónde arrancamos:',
    ayuda =
'<b>Soy tu asistente de negocio</b>

No sos vos el que trabaja para el sistema: me mandás lo que ya tenés —las facturas de venta y de compra, como las exporte tu programa o te las pase el contador— y de ahí en adelante trabajo yo.

<b>Con eso te ayudo a:</b>

📊 <b>Entender tus números.</b> Qué producto te deja plata y cuál te la quita, a cuál le subió el costo, qué se te está quedando quieto en la bodega.

💰 <b>Cobrar.</b> Quién te debe, cuánto y desde cuándo, y a quién conviene llamar primero esta semana.

⏰ <b>No olvidarte de nada.</b> Lo que hay que pagar, pedir o revisar, avisado cuando todavía sirve.

🔔 <b>Enterarte a tiempo.</b> Se agota algo que rota, un proveedor te subió el precio, un cliente se atrasó más de lo que suele.

🧭 <b>Decidir.</b> No solo el dato: cuánto te está costando cada problema y qué conviene hacer primero.

💬 <b>Contestarte.</b> Preguntame lo que quieras de tu negocio y te respondo con tus propios datos.

Cuanta más historia me des, mejor: con tres meses ya sale un análisis serio.

⚠️ Todo esto lo produce una <b>inteligencia artificial</b>: puede equivocarse y no reemplaza a tu contador.'
WHERE codigo = 'negocio';

-- =============================================================================
-- 5. Avisar lo que quedó fuera del plan gratuito
-- =============================================================================
-- Copia de la 042 con `aviso_plan` agregado: si el trigger descartó filas, el
-- resumen de la sesión lo dice y ofrece el camino para no perderlas.
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
    fuera AS (SELECT coalesce(sum(filas_fuera_de_plan), 0)::int AS n FROM docs)
    SELECT jsonb_build_object(
        'archivos', (SELECT count(*) FROM docs),
        'detalle',  coalesce((SELECT string_agg(
                        format('📄 %s: %s registros, $%s',
                               nombre_archivo, filas, miles(total)),
                        E'\n' ORDER BY id) FROM docs), ''),
        'total',    '$' || miles((SELECT coalesce(sum(total), 0) FROM docs)),
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
        -- >>> 051: lo que el plan gratuito dejó por fuera.
        'aviso_plan', CASE WHEN (SELECT n FROM fuera) > 0
                     THEN format(E'\n\n🎁 Dejé por fuera %s registros más viejos que %s meses: el plan gratuito cubre esa ventana. Si querés que analice toda tu historia, mirá /plan.',
                                 (SELECT n FROM fuera),
                                 coalesce((parametro(NULL, 'plan_free_meses_historia'))::text, '3'))
                     ELSE '' END
    );
$$;

UPDATE plantillas SET cuerpo =
'Esto fue lo que cargué:

{{detalle}}

Total: {{total}}{{aviso_nit}}{{aviso_plan}}',
  variables = '["archivos","detalle","total","aviso_nit","aviso_plan"]'::jsonb,
  version = version + 1
WHERE clave = 'ingesta.resumen_sesion';

-- =============================================================================
-- 6. Router
-- =============================================================================
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
    ELSIF v_texto LIKE 'acepto:%' THEN
        -- >>> 051: 'acepto:<mensaje original>' — el consentimiento se lleva
        -- puesto el paso que lo disparó para poder retomarlo.
        v_arg := btrim(substring(v_texto FROM 8));
        v_cmd := 'acepto';
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
                     p_evento || jsonb_build_object('texto', v_arg));
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
