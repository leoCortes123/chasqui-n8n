-- 000_esquema.sql — el esquema completo de Chasqui v0.
--
-- GENERADO por bin/gen_base.sh desde el catálogo vivo. No editar a mano.
--
-- Reemplaza a las 73 migraciones que lo construyeron, archivadas en
-- docs/historico/migraciones/. El porqué de cada pieza vive ahora en
-- decisiones/; el qué existe, en db/actual/INDICE.md.
--
-- Las extensiones (pgcrypto, pg_trgm, unaccent) las instala db/init/00_bases.sh
-- con el superusuario, igual que antes: el dueño de la base no siempre puede.
--
-- check_function_bodies: pg_dump emite las funciones antes que las tablas, y las
-- de LANGUAGE sql validan su cuerpo al crearse. Sin esto, la primera que consulte
-- una tabla que todavía no existe aborta el archivo entero.
SET check_function_bodies = false;






CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;



CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;



CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA public;



CREATE TYPE public.estado_doc AS ENUM (
    'pendiente',
    'parseado',
    'error'
);



CREATE TYPE public.estado_ejec AS ENUM (
    'preparando',
    'procesando',
    'validando',
    'completada',
    'fallida',
    'bloqueada'
);



CREATE TYPE public.estado_sesion AS ENUM (
    'intake',
    'recibiendo',
    'procesando',
    'completada',
    'fallida',
    'expirada'
);



CREATE TYPE public.origen_alias AS ENUM (
    'exacto',
    'trigram',
    'manual',
    'pendiente'
);



CREATE TYPE public.rol_usuario AS ENUM (
    'dueno',
    'operador',
    'admin'
);



CREATE TYPE public.tipo_movimiento AS ENUM (
    'compra',
    'venta',
    'ajuste'
);



CREATE FUNCTION public.admin_reporte(p_cmd text) RETURNS text
    LANGUAGE plpgsql STABLE
    AS $_$
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
$_$;



CREATE FUNCTION public.alertas_evaluar() RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_cool  int  := coalesce((parametro(NULL,'alerta_cooldown_dias'))::text::int, 14);
    v_desde int  := coalesce((parametro(NULL,'alerta_hora_desde'))::text::int, 8);
    v_hasta int  := coalesce((parametro(NULL,'alerta_hora_hasta'))::text::int, 20);
    v_max   int  := coalesce((parametro(NULL,'alerta_max_por_corrida'))::text::int, 1);
    v_tz    text := coalesce(btrim((parametro(NULL,'zona_horaria'))::text, '"'),
                             'America/Bogota');
    v_hora  int;
    v_notif jsonb := '[]'::jsonb;
    n       record;
    a       record;
BEGIN
    v_hora := extract(hour FROM (now() AT TIME ZONE v_tz))::int;
    IF v_hora < v_desde OR v_hora >= v_hasta THEN
        -- Fuera de horario no se evalúa siquiera: además de no molestar, se
        -- ahorra recorrer las reglas de todos los negocios de madrugada.
        RETURN jsonb_build_object('corrido_en', now(), 'fuera_de_horario', true,
                                  'notificaciones', '[]'::jsonb);
    END IF;

    FOR n IN SELECT * FROM v_negocios_alertables LOOP
        -- Se usa la MISMA función que el informe, en modo registro para ver
        -- todo lo detectado. Es una lectura pura: no escribe recomendaciones ni
        -- toca `veces_vista` — eso solo pasa cuando hay un informe de verdad.
        SELECT e.regla, e.clave_objeto, e.titulo, e.problema, e.impacto,
               e.impacto_mes, e.icono
          INTO a
        FROM jsonb_to_recordset(recomendaciones_negocio(n.negocio_id, true))
               AS e(regla text, clave_objeto text, titulo text, problema text,
                    impacto text, impacto_mes numeric, prioridad text, icono text)
        WHERE e.prioridad = 'alta'
          AND NOT EXISTS (
                SELECT 1 FROM alertas_enviadas al
                 WHERE al.negocio_id = n.negocio_id
                   AND al.regla = e.regla AND al.clave_objeto = e.clave_objeto
                   AND al.enviada_en > now() - make_interval(days => v_cool))
        ORDER BY e.impacto_mes DESC NULLS LAST
        LIMIT v_max;

        CONTINUE WHEN a.regla IS NULL;

        INSERT INTO alertas_enviadas (negocio_id, regla, clave_objeto, prioridad, titulo)
        VALUES (n.negocio_id, a.regla, a.clave_objeto, 'alta', a.titulo);

        v_notif := v_notif || jsonb_build_array(jsonb_build_object(
          'chat_id', n.chat_id,
          'respuestas', jsonb_build_array(jsonb_build_object(
            'plantilla', 'alerta.hallazgo',
            'vars', jsonb_build_object(
              'icono',    coalesce(a.icono, '🔔'),
              'titulo',   a.titulo,
              'problema', coalesce(a.problema, ''),
              'impacto',  coalesce(a.impacto, ''))))));
    END LOOP;

    RETURN jsonb_build_object('corrido_en', now(), 'notificaciones', v_notif);
END;
$$;



CREATE FUNCTION public.alias_pendientes(p_negocio_id bigint, p_limite integer DEFAULT 50) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
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



CREATE FUNCTION public.b64url(p bytea) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT rtrim(translate(replace(encode(p, 'base64'), E'\n', ''), '+/', '-_'), '=');
$$;



CREATE FUNCTION public.barra_10(p_valor numeric) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT repeat('█', greatest(0, least(10, round(coalesce(p_valor,0)/10)::int)))
        || repeat('░', 10 - greatest(0, least(10, round(coalesce(p_valor,0)/10)::int)));
$$;



CREATE FUNCTION public.canal_de_chat(p_chat_id bigint) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    SELECT coalesce(
        (SELECT canal FROM identidades
          WHERE datos ->> 'chat_id' = p_chat_id::text
          ORDER BY vista_en DESC LIMIT 1),
        'telegram');
$$;



CREATE FUNCTION public.carga_arrancar(p_sesion_id bigint) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
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



CREATE FUNCTION public.carga_evaluar(p_sesion_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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



CREATE FUNCTION public.carga_hay_con_que(p_sesion_id bigint) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
    SELECT EXISTS (SELECT 1 FROM documentos
                    WHERE sesion_id = p_sesion_id AND estado = 'parseado')
        OR EXISTS (SELECT 1 FROM sesiones s
                    WHERE s.id = p_sesion_id
                      AND s.servicio_codigo = 'mercado_compras'
                      AND EXISTS (SELECT 1 FROM mov_visibles v
                                   WHERE v.negocio_id = s.negocio_id
                                     AND v.tipo = 'compra'));
$$;



CREATE FUNCTION public.carga_panel(p_sesion_id bigint, p_modo text DEFAULT 'panel'::text) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $$
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



CREATE FUNCTION public.carga_panel_registrar(p_sesion_id bigint, p_mensaje_id bigint) RETURNS void
    LANGUAGE sql
    AS $$
    UPDATE sesiones SET panel_mensaje_id = p_mensaje_id WHERE id = p_sesion_id;
$$;



CREATE FUNCTION public.carga_registrar_fallo(p_sesion_id bigint, p_nombre text) RETURNS void
    LANGUAGE sql
    AS $$
    UPDATE sesiones
       SET contexto = jsonb_set(contexto, '{descargas_fallidas}',
             coalesce(contexto -> 'descargas_fallidas', '[]'::jsonb)
               || to_jsonb(coalesce(nullif(btrim(p_nombre), ''), 'un archivo')),
             true)
     WHERE id = p_sesion_id;
$$;



CREATE FUNCTION public.carga_resumen(p_sesion_id bigint) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
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



CREATE FUNCTION public.cartera_facturar_dian(p_documento_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $_$
DECLARE
    v_negocio_id  bigint;
    v_xml         xml;
    v_raiz        text;
    v_nit_negocio text;
    v_nit_emisor  text;
    v_nombre_emisor  text;
    v_nit_cliente    text;
    v_nombre_cliente text;
    v_tipo        tipo_movimiento;
    v_tercero_id  bigint;
    v_num         text;
    v_emision     date;
    v_vence       date;
    v_total       numeric;
    v_factura_id  bigint;
BEGIN
    SELECT d.negocio_id, convert_from(d.contenido, 'UTF8')::xml,
           nullif(btrim(coalesce(n.nit, '')), '')
      INTO v_negocio_id, v_xml, v_nit_negocio
    FROM documentos d JOIN negocios n ON n.id = d.negocio_id
    WHERE d.id = p_documento_id;

    v_raiz := (xpath('local-name(/*)', v_xml))[1]::text;
    IF v_raiz = 'AttachedDocument' THEN
        v_xml := regexp_replace(
                   regexp_replace(
                     (xpath('//*[local-name()="Attachment"]//*[local-name()="Description"]/text()', v_xml))[1]::text,
                     '^\s*<!\[CDATA\[', ''),
                   '\]\]>\s*$', '')::xml;
        v_raiz := (xpath('local-name(/*)', v_xml))[1]::text;
    END IF;

    IF v_raiz <> 'Invoice' THEN
        RETURN jsonb_build_object('documento_id', p_documento_id,
                                  'factura', false, 'motivo', v_raiz);
    END IF;

    -- Cabecera. El NIT es el CompanyID del PartyTaxScheme; el primero que
    -- aparezca bajo cada Party sirve porque DIAN lo repite idéntico.
    v_num     := (xpath('/*/*[local-name()="ID"][1]/text()', v_xml))[1]::text;
    v_emision := (xpath('/*/*[local-name()="IssueDate"][1]/text()', v_xml))[1]::text::date;
    v_vence   := coalesce(
        (xpath('/*/*[local-name()="DueDate"][1]/text()', v_xml))[1]::text::date,
        (xpath('//*[local-name()="PaymentMeans"]/*[local-name()="PaymentDueDate"][1]/text()', v_xml))[1]::text::date);
    v_total   := (xpath('//*[local-name()="LegalMonetaryTotal"]/*[local-name()="PayableAmount"]/text()', v_xml))[1]::text::numeric;

    v_nit_emisor     := (xpath('//*[local-name()="AccountingSupplierParty"]//*[local-name()="CompanyID"][1]/text()', v_xml))[1]::text;
    v_nombre_emisor  := (xpath('//*[local-name()="AccountingSupplierParty"]//*[local-name()="RegistrationName"][1]/text()', v_xml))[1]::text;
    v_nit_cliente    := (xpath('//*[local-name()="AccountingCustomerParty"]//*[local-name()="CompanyID"][1]/text()', v_xml))[1]::text;
    v_nombre_cliente := (xpath('//*[local-name()="AccountingCustomerParty"]//*[local-name()="RegistrationName"][1]/text()', v_xml))[1]::text;

    -- El lado del mostrador: emisor yo = venta al cliente; si no, compra.
    IF v_nit_negocio IS NOT NULL AND btrim(coalesce(v_nit_emisor, '')) = v_nit_negocio THEN
        v_tipo := 'venta';
        v_tercero_id := tercero_obtener(v_negocio_id, v_nit_cliente, v_nombre_cliente);
    ELSE
        v_tipo := 'compra';
        v_tercero_id := tercero_obtener(v_negocio_id, v_nit_emisor, v_nombre_emisor);
    END IF;

    INSERT INTO facturas (negocio_id, tercero_id, documento_id, tipo, numero,
                          emision, vencimiento, total, saldo)
    VALUES (v_negocio_id, v_tercero_id, p_documento_id, v_tipo, v_num,
            v_emision, v_vence, coalesce(v_total, 0), coalesce(v_total, 0))
    ON CONFLICT (documento_id) DO UPDATE
      SET tercero_id = EXCLUDED.tercero_id, tipo = EXCLUDED.tipo,
          numero = EXCLUDED.numero, emision = EXCLUDED.emision,
          vencimiento = EXCLUDED.vencimiento, total = EXCLUDED.total,
          -- el saldo conserva lo ya pagado aunque se re-facture el documento
          saldo = EXCLUDED.total - (facturas.total - facturas.saldo)
    RETURNING id INTO v_factura_id;

    UPDATE movimientos SET tercero_id = v_tercero_id, tipo = v_tipo
    WHERE documento_id = p_documento_id;

    RETURN jsonb_build_object('documento_id', p_documento_id, 'factura', true,
                              'factura_id', v_factura_id, 'tipo', v_tipo,
                              'numero', v_num, 'vencimiento', v_vence,
                              'total', v_total);
END;
$_$;



CREATE FUNCTION public.cartera_refacturar(p_negocio_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE r record;
BEGIN
    FOR r IN SELECT id FROM documentos
             WHERE negocio_id = p_negocio_id
               AND formato_codigo = 'dian_xml' AND estado = 'parseado' LOOP
        BEGIN
            PERFORM cartera_facturar_dian(r.id);
        EXCEPTION WHEN OTHERS THEN
            -- un XML viejo ilegible no debe frenar el cambio de NIT
            NULL;
        END;
    END LOOP;
END;
$$;



CREATE FUNCTION public.chat_de_usuario(p_usuario_id bigint) RETURNS bigint
    LANGUAGE sql STABLE
    AS $$
    SELECT coalesce(
        (SELECT (datos ->> 'chat_id')::bigint FROM identidades
          WHERE usuario_id = p_usuario_id AND datos ? 'chat_id'
          ORDER BY vista_en DESC LIMIT 1),
        (SELECT telegram_chat_id FROM usuarios WHERE id = p_usuario_id));
$$;



CREATE FUNCTION public.cifra_norm(p_num text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $_$
    SELECT CASE WHEN strpos(coalesce(p_num, ''), '.') = 0 THEN coalesce(p_num, '')
                ELSE regexp_replace(regexp_replace(p_num, '0+$', ''), '\.$', '') END;
$_$;



CREATE FUNCTION public.cifra_variantes(p_num text) RETURNS text[]
    LANGUAGE plpgsql IMMUTABLE
    AS $_$
DECLARE
    v_t    text := rtrim(coalesce(p_num, ''), '.,');   -- puntuación de la frase
    v_pre  text;
    v_cola text;
    v_out  text[];
BEGIN
    IF v_t = '' THEN RETURN '{}'; END IF;

    v_out := ARRAY[ cifra_norm(regexp_replace(v_t, '[.,]', '', 'g')) ];

    IF v_t ~ '[.,]' THEN
        v_pre  := regexp_replace(v_t, '[.,][^.,]*$', '');   -- antes del último separador
        v_cola := regexp_replace(v_t, '^.*[.,]', '');       -- después del último separador
        v_out  := v_out || cifra_norm(
            regexp_replace(v_pre, '[.,]', '', 'g') || '.' || v_cola);
    END IF;

    RETURN ARRAY(SELECT DISTINCT x FROM unnest(v_out) AS x WHERE x <> '');
END;
$_$;



CREATE FUNCTION public.conocimiento_buscar(p_negocio_id bigint, p_texto text, p_limite integer DEFAULT 8, p_umbral numeric DEFAULT 0.12) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
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



CREATE FUNCTION public.conocimiento_guardar(p_negocio_id bigint, p_tipo text, p_titulo text, p_contenido text DEFAULT NULL::text, p_clave text DEFAULT NULL::text, p_datos jsonb DEFAULT '{}'::jsonb, p_origen text DEFAULT 'portal'::text, p_usuario_id bigint DEFAULT NULL::bigint, p_pendiente_id bigint DEFAULT NULL::bigint) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
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



CREATE FUNCTION public.conocimiento_pendiente_registrar(p_negocio_id bigint, p_pregunta text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
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



CREATE FUNCTION public.consulta_iniciar(p_usuario_id bigint, p_negocio_id bigint, p_chat_id bigint, p_pregunta text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_hechos   jsonb;
    v_hay_kb   boolean;
    v_hay_num  boolean;
    v_sesion   bigint;
    v_ejec     bigint;
BEGIN
    v_hechos := conocimiento_buscar(p_negocio_id, p_pregunta);
    v_hay_kb := v_hechos IS NOT NULL AND jsonb_array_length(v_hechos) > 0;

    -- `mov_visibles` y no `movimientos`: la compuerta tiene que coincidir con
    -- lo que el análisis va a poder usar de verdad (C9/053).
    SELECT EXISTS (SELECT 1 FROM mov_visibles WHERE negocio_id = p_negocio_id)
      INTO v_hay_num;

    IF NOT v_hay_kb AND NOT v_hay_num THEN
        -- Sin KB y sin números no hay nada que responder. La pregunta se
        -- registra: es señal de qué le falta a la base de conocimiento.
        PERFORM conocimiento_pendiente_registrar(p_negocio_id, p_pregunta);
        RETURN router_respuesta(p_chat_id, 'consulta.sin_datos');
    END IF;

    -- Si hay números pero la KB no tenía nada, la pregunta igual se anota: que
    -- se pueda responder con agregados no quita que un dato cargado a mano la
    -- respondería mejor.
    IF NOT v_hay_kb THEN
        PERFORM conocimiento_pendiente_registrar(p_negocio_id, p_pregunta);
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



CREATE FUNCTION public.contexto_negocio_recuperar(p_negocio_id bigint, p_contexto jsonb) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_pregunta text := btrim(coalesce(p_contexto ->> 'pregunta', ''));
    v_perfil   jsonb := perfil_negocio(p_negocio_id);
    v_hechos   jsonb := conocimiento_buscar(p_negocio_id, v_pregunta);
BEGIN
    RETURN jsonb_build_object(
        'negocio_id', p_negocio_id,
        'generado_en', now(),
        'pregunta', v_pregunta,

        -- La KB, tal cual. No se toca: cuando la pregunta es por un precio o
        -- por el horario, lo que alguien escribió a mano le gana a cualquier
        -- agregado.
        'hechos', coalesce(v_hechos, '[]'::jsonb),

        -- >>> 063: si la pregunta pide un número puntual, acá está calculado.
        -- NULL cuando ninguna intención coincide.
        'consulta', intencion_resolver(p_negocio_id, v_pregunta),

        -- >>> 062: los números, que es lo que faltaba.
        'negocio', jsonb_build_object(
            'tipo',            v_perfil -> 'tipo',
            'periodo',         v_perfil -> 'periodo',
            'productos',       v_perfil -> 'productos',
            'top_productos',   v_perfil -> 'top_productos',
            'proveedores',     v_perfil -> 'proveedores',
            'estacionalidad',  v_perfil -> 'estacionalidad',
            'problemas_recurrentes', v_perfil -> 'problemas_recurrentes',
            'acciones',        v_perfil -> 'acciones',
            'calidad',         v_perfil -> 'calidad'),

        'estado', salud_negocio(p_negocio_id),
        'comparativo', hallazgos_comparativo(p_negocio_id),
        'recomendaciones', recomendaciones_vigentes(p_negocio_id, 8),

        'encabezado', jsonb_build_object(
            'titulo', 'Tu pregunta',
            'subtitulo', v_pregunta,
            'metricas', '[]'::jsonb));
END;
$$;



CREATE FUNCTION public.ejecucion_cerrar(p_ejecucion_id bigint, p_estado text, p_resultado jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_sesion_id  bigint;
    v_servicio   text;
    v_negocio_id bigint;
    v_chat       bigint;
    v_plantilla  text := 'ejecucion.entregada';
    v_snapshot   bigint;
    v_recos      jsonb;
    v_medido     jsonb;
BEGIN
    UPDATE ejecuciones SET
        estado        = p_estado::estado_ejec,
        texto         = coalesce(p_resultado ->> 'texto', texto),
        tokens_prompt = coalesce((p_resultado ->> 'tokens_prompt')::int, tokens_prompt),
        tokens_salida = coalesce((p_resultado ->> 'tokens_salida')::int, tokens_salida),
        costo         = coalesce((p_resultado ->> 'costo')::numeric, costo),
        pdf           = coalesce(decode(p_resultado ->> 'pdf_base64', 'base64'), pdf),
        error         = p_resultado ->> 'error',
        fin           = now()
    WHERE id = p_ejecucion_id
    RETURNING sesion_id, servicio_codigo, negocio_id
         INTO v_sesion_id, v_servicio, v_negocio_id;

    IF v_sesion_id IS NOT NULL THEN
        SELECT chat_de_usuario(s.usuario_id) INTO v_chat
        FROM sesiones s WHERE s.id = v_sesion_id;

        UPDATE sesiones SET
            estado     = CASE WHEN p_estado = 'completada' THEN 'completada'::estado_sesion
                              ELSE 'fallida'::estado_sesion END,
            cerrada_en = now()
        WHERE id = v_sesion_id;
    END IF;

    IF p_estado = 'completada' AND v_negocio_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM servicios
                    WHERE codigo = v_servicio AND entrada = 'archivos') THEN
        -- >>> 058: la memoria del estado del negocio.
        BEGIN
            v_snapshot := snapshot_tomar(v_negocio_id, 'ejecucion', p_ejecucion_id);
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO fallas (workflow, ejecucion_id, sesion_id, tipo, transitoria, detalle)
            VALUES ('snapshot_tomar', p_ejecucion_id, v_sesion_id, 'permanente', false,
                    jsonb_build_object('mensaje', SQLERRM, 'sqlstate', SQLSTATE));
        END;

        -- >>> 059: la memoria de lo que se le recomendó (R-III).
        BEGIN
            v_recos := recomendaciones_registrar(v_negocio_id, p_ejecucion_id);
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO fallas (workflow, ejecucion_id, sesion_id, tipo, transitoria, detalle)
            VALUES ('recomendaciones_registrar', p_ejecucion_id, v_sesion_id,
                    'permanente', false,
                    jsonb_build_object('mensaje', SQLERRM, 'sqlstate', SQLSTATE));
        END;

        -- >>> 066: ¿sirvió lo que se recomendó antes? Va DESPUÉS del registro
        -- porque el registro es el que cierra por dato, y lo que acaba de
        -- cerrarse ya puede empezar a medirse en la corrida siguiente.
        BEGIN
            v_medido := recomendaciones_medir(v_negocio_id);
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO fallas (workflow, ejecucion_id, sesion_id, tipo, transitoria, detalle)
            VALUES ('recomendaciones_medir', p_ejecucion_id, v_sesion_id,
                    'permanente', false,
                    jsonb_build_object('mensaje', SQLERRM, 'sqlstate', SQLSTATE));
        END;
    END IF;

    IF EXISTS (SELECT 1 FROM plantillas
                WHERE clave = 'ejecucion.entregada.' || coalesce(v_servicio, '—')
                  AND activo) THEN
        v_plantilla := 'ejecucion.entregada.' || v_servicio;
    END IF;

    RETURN jsonb_build_object('ejecucion_id', p_ejecucion_id, 'estado', p_estado,
                              'chat_id', v_chat, 'servicio_codigo', v_servicio,
                              'plantilla_entrega', v_plantilla,
                              'snapshot_id', v_snapshot,
                              'recomendaciones', v_recos,
                              'resultados', v_medido);
END;
$$;



CREATE FUNCTION public.ejecucion_preparar(p_ejecucion_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $_$
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
$_$;



CREATE FUNCTION public.esc_html(p_texto text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT replace(replace(replace(coalesce(p_texto, ''),
             '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
$$;



CREATE FUNCTION public.extensiones_aceptadas() RETURNS text
    LANGUAGE sql STABLE
    AS $$
    SELECT string_agg(DISTINCT upper(ext), ', ' ORDER BY upper(ext))
    FROM (
        SELECT jsonb_object_keys(parametro(NULL, 'ingesta_extractores')) AS ext
        UNION
        SELECT unnest(extensiones) FROM formatos_documento
         WHERE activo AND clase = 'documento'
    ) t;
$$;



CREATE FUNCTION public.fmt_decimal(p_num numeric) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $_$
    SELECT CASE WHEN p_num IS NULL THEN ''
      ELSE replace(regexp_replace(regexp_replace(p_num::text, '0+$', ''), '\.$', ''),
                   '.', ',') END;
$_$;



CREATE FUNCTION public.hallazgos_comparativo(p_negocio_id bigint) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_ant jsonb := snapshot_anterior(p_negocio_id);
    v_sal jsonb;
BEGIN
    IF v_ant IS NULL THEN RETURN NULL; END IF;
    v_sal := salud_negocio(p_negocio_id);

    RETURN jsonb_strip_nulls(jsonb_build_object(
      'fecha_anterior',  v_ant ->> 'fecha',
      'parcial',         coalesce((v_ant #> '{metricas,parcial}')::boolean, false),
      'salud_anterior',  v_ant #> '{salud,indice}',
      'salud_actual',    v_sal -> 'indice',
      -- El delta viene calculado desde SQL. Si se lo dejáramos al modelo,
      -- estaríamos moviéndole una resta, y `validar_cifras` rechazaría el
      -- resultado por no estar en los hallazgos (R-I).
      'salud_delta',     CASE WHEN v_ant #> '{salud,indice}' IS NOT NULL
                               AND v_sal -> 'indice' IS NOT NULL
                              THEN to_jsonb((v_sal ->> 'indice')::numeric
                                            - (v_ant #>> '{salud,indice}')::numeric) END,
      'ventas_anterior',  v_ant #> '{metricas,totales,ventas}',
      'compras_anterior', v_ant #> '{metricas,totales,compras}'));
END;
$$;



CREATE FUNCTION public.hallazgos_compras(p_negocio_id bigint) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_deriva_ali numeric := (parametro(p_negocio_id, 'deriva_costo_alerta_pct'))::text::numeric;
    v_out jsonb;
BEGIN
    WITH compras AS (
        SELECT m.*, coalesce(p.nombre_canonico, m.raw ->> 'descripcion',
                             m.raw ->> 'producto', 'sin nombre') AS etiqueta,
               nullif(btrim(coalesce(m.raw ->> 'proveedor', '')), '') AS proveedor
        FROM mov_visibles m
        LEFT JOIN productos p ON p.id = m.producto_id
        WHERE m.negocio_id = p_negocio_id AND m.tipo = 'compra'
    ),
    gasto AS (SELECT sum(valor_total) AS total FROM compras)
    SELECT jsonb_build_object(
      'negocio_id', p_negocio_id,
      'generado_en', now(),

      'periodo', (SELECT jsonb_build_object(
                    'desde', min(fecha), 'hasta', max(fecha),
                    'movimientos_compra', count(*))
                  FROM compras WHERE fecha IS NOT NULL),

      'resumen', (SELECT jsonb_build_object(
                    'productos',   count(DISTINCT etiqueta),
                    'gasto_total', round(coalesce(sum(valor_total), 0)),
                    'proveedores', count(DISTINCT proveedor) FILTER (WHERE proveedor IS NOT NULL),
                    'documentos',  count(DISTINCT documento_id))
                  FROM compras),

      -- Dónde se va la plata: top de gasto por producto con su participación.
      'gasto_producto', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                           'producto', etiqueta, 'gasto', gasto_p,
                           'unidades', unidades, 'pct_gasto', pct) ORDER BY gasto_p DESC), '[]')
                         FROM (SELECT etiqueta,
                                      round(sum(valor_total)) AS gasto_p,
                                      round(sum(cantidad))    AS unidades,
                                      round((sum(valor_total) * 100.0
                                             / nullif((SELECT total FROM gasto), 0))::numeric, 1) AS pct
                               FROM compras GROUP BY etiqueta
                               ORDER BY sum(valor_total) DESC NULLS LAST LIMIT 8) t),

      -- Costo al alza: misma vista y mismo umbral que el análisis de ventas.
      'deriva_costo', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                         'producto_id', d.producto_id, 'producto', p.nombre_canonico,
                         'costo_ini', d.costo_ini, 'costo_fin', d.costo_fin,
                         'deriva_pct', d.deriva_pct) ORDER BY abs(d.deriva_pct) DESC), '[]')
                       FROM v_deriva_costo d JOIN productos p ON p.id = d.producto_id
                       WHERE d.negocio_id = p_negocio_id
                         AND abs(d.deriva_pct) >= v_deriva_ali),

      -- Precios muy distintos por el mismo producto: margen para negociar.
      'precio_disperso', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                            'producto', etiqueta, 'precio_min', pmin,
                            'precio_max', pmax, 'dispersion_pct', disp)
                            ORDER BY disp DESC), '[]')
                          FROM (SELECT etiqueta,
                                       round(min(valor_unitario)) AS pmin,
                                       round(max(valor_unitario)) AS pmax,
                                       round(((max(valor_unitario) - min(valor_unitario))
                                              / nullif(min(valor_unitario), 0) * 100)::numeric, 1) AS disp
                                FROM compras WHERE valor_unitario > 0
                                GROUP BY etiqueta
                                HAVING count(*) > 1
                                   AND (max(valor_unitario) - min(valor_unitario))
                                       / nullif(min(valor_unitario), 0) >= 0.10
                                ORDER BY disp DESC LIMIT 8) t),

      -- Peso de cada proveedor en el gasto.
      'proveedores', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'proveedor', coalesce(proveedor, 'sin dato'),
                        'gasto', gasto_v, 'pct_gasto', pct) ORDER BY gasto_v DESC), '[]')
                      FROM (SELECT proveedor, round(sum(valor_total)) AS gasto_v,
                                   round((sum(valor_total) * 100.0
                                          / nullif((SELECT total FROM gasto), 0))::numeric, 1) AS pct
                            FROM compras GROUP BY proveedor
                            ORDER BY sum(valor_total) DESC NULLS LAST LIMIT 6) t),

      -- Comprado que no registra ni una venta: plata quieta. Solo tiene sentido
      -- si el negocio también carga ventas; si no hay ventas, va vacío y el
      -- prompt no arma la sección.
      'sin_venta', CASE WHEN EXISTS (SELECT 1 FROM mov_visibles
                                     WHERE negocio_id = p_negocio_id AND tipo = 'venta')
                   THEN (SELECT coalesce(jsonb_agg(jsonb_build_object(
                           'producto', etiqueta, 'unidades', unidades, 'gasto', gasto_p)
                           ORDER BY gasto_p DESC), '[]')
                         FROM (SELECT c.etiqueta, round(sum(c.cantidad)) AS unidades,
                                      round(sum(c.valor_total)) AS gasto_p
                               FROM compras c
                               WHERE c.producto_id IS NOT NULL
                                 AND NOT EXISTS (SELECT 1 FROM mov_visibles v
                                                 WHERE v.negocio_id = p_negocio_id
                                                   AND v.tipo = 'venta'
                                                   AND v.producto_id = c.producto_id)
                               GROUP BY c.etiqueta
                               ORDER BY sum(c.valor_total) DESC LIMIT 8) t)
                   ELSE '[]'::jsonb END
    ) INTO v_out;

    RETURN v_out;
END;
$$;



CREATE FUNCTION public.hallazgos_compras(p_negocio_id bigint, p_contexto jsonb) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
    SELECT hallazgos_compras(p_negocio_id)
           || jsonb_build_object(
                'salud', salud_negocio(p_negocio_id),
                'recomendaciones', recomendaciones_negocio(p_negocio_id),
                'tipo_negocio', (SELECT coalesce(t.nombre, n.tipo)
                                 FROM negocios n
                                 LEFT JOIN tipos_negocio t ON t.codigo = n.tipo
                                 WHERE n.id = p_negocio_id));
$$;



CREATE FUNCTION public.hallazgos_generar(p_negocio_id bigint) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_margen_min  numeric := (parametro(p_negocio_id, 'margen_minimo_pct'))::text::numeric;
    v_deriva_ali  numeric := (parametro(p_negocio_id, 'deriva_costo_alerta_pct'))::text::numeric;
    v_dias_cob    numeric := (parametro(p_negocio_id, 'dias_cobertura_min'))::text::numeric;
    v_out jsonb;
BEGIN
    SELECT jsonb_build_object(
      'negocio_id', p_negocio_id,
      'generado_en', now(),
      'tipo_negocio', (SELECT coalesce(t.nombre, n.tipo)
                       FROM negocios n
                       LEFT JOIN tipos_negocio t ON t.codigo = n.tipo
                       WHERE n.id = p_negocio_id),
      'umbrales', jsonb_build_object('margen_minimo_pct', v_margen_min,
                                     'deriva_costo_alerta_pct', v_deriva_ali,
                                     'dias_cobertura_min', v_dias_cob),

      'salud', salud_negocio(p_negocio_id),
      'recomendaciones', recomendaciones_negocio(p_negocio_id),

      -- >>> 060: cómo estaba el negocio la vez pasada.
      'comparativo', hallazgos_comparativo(p_negocio_id),

      'periodo', (SELECT jsonb_build_object(
                    'desde', min(fecha), 'hasta', max(fecha),
                    'movimientos_venta',  count(*) FILTER (WHERE tipo = 'venta'),
                    'movimientos_compra', count(*) FILTER (WHERE tipo = 'compra'))
                  FROM mov_visibles
                  WHERE negocio_id = p_negocio_id AND fecha IS NOT NULL),

      'resumen', (SELECT jsonb_build_object(
                    'productos', count(*),
                    'con_precio', count(*) FILTER (WHERE precio_actual IS NOT NULL),
                    'margen_promedio_pct', round(avg(margen_pct), 2))
                  FROM v_margen_producto WHERE negocio_id = p_negocio_id),

      'margen_bajo', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'producto', nombre_canonico, 'costo', costo_actual,
                        'precio', precio_actual, 'margen_pct', margen_pct)
                        ORDER BY margen_pct), '[]')
                      FROM v_margen_producto
                      WHERE negocio_id = p_negocio_id
                        AND precio_actual IS NOT NULL
                        AND margen_pct < v_margen_min),

      'deriva_costo', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'producto_id', d.producto_id, 'producto', p.nombre_canonico,
                        'costo_ini', d.costo_ini, 'costo_fin', d.costo_fin,
                        'deriva_pct', d.deriva_pct) ORDER BY abs(d.deriva_pct) DESC), '[]')
                      FROM v_deriva_costo d JOIN productos p ON p.id = d.producto_id
                      WHERE d.negocio_id = p_negocio_id
                        AND abs(d.deriva_pct) >= v_deriva_ali),

      'baja_cobertura', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'producto_id', r.producto_id, 'producto', p.nombre_canonico,
                        'dias_cobertura', r.dias_cobertura,
                        'unidades_por_dia', r.unidades_por_dia) ORDER BY r.dias_cobertura), '[]')
                      FROM v_rotacion_producto r JOIN productos p ON p.id = r.producto_id
                      WHERE r.negocio_id = p_negocio_id
                        AND r.dias_cobertura IS NOT NULL
                        AND r.dias_cobertura < v_dias_cob),

      'pareto', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'producto', p.nombre_canonico, 'utilidad', pa.utilidad,
                        'pct_utilidad', pa.pct_utilidad, 'pct_acumulado', pa.pct_acumulado)
                        ORDER BY pa.utilidad DESC), '[]')
                      FROM v_pareto_utilidad pa JOIN productos p ON p.id = pa.producto_id
                      WHERE pa.negocio_id = p_negocio_id AND pa.pct_acumulado <= 80)
    ) INTO v_out;

    RETURN v_out;
END;
$$;



CREATE FUNCTION public.hallazgos_generar(p_negocio_id bigint, p_contexto jsonb) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
    SELECT hallazgos_generar(p_negocio_id);
$$;



CREATE FUNCTION public.informe_base_bloque(p_hallazgos jsonb, p_servicio text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_neg      bigint := (p_hallazgos ->> 'negocio_id')::bigint;
    v_lineas   text[] := '{}';
    v_archivos bigint;
    v_vis      bigint;
    v_total    bigint;
    v_ocultos  bigint;
    v_ventas   bigint;
    v_compras  bigint;
    v_desde    date;
    v_hasta    date;
    v_sin_nit  boolean;
BEGIN
    IF v_neg IS NULL THEN RETURN NULL; END IF;

    SELECT count(DISTINCT m.documento_id) FILTER (WHERE m.documento_id IS NOT NULL),
           count(*)
      INTO v_archivos, v_total
    FROM movimientos m WHERE m.negocio_id = v_neg;

    IF v_total = 0 THEN RETURN NULL; END IF;

    SELECT count(*),
           count(*) FILTER (WHERE tipo = 'venta'),
           count(*) FILTER (WHERE tipo = 'compra'),
           min(fecha), max(fecha)
      INTO v_vis, v_ventas, v_compras, v_desde, v_hasta
    FROM mov_visibles WHERE negocio_id = v_neg;

    v_ocultos := v_total - v_vis;

    v_lineas := v_lineas || format('📄 Salió de <b>%s</b> %s tuyos: <b>%s</b> %s.',
        miles(v_archivos), CASE WHEN v_archivos = 1 THEN 'archivo' ELSE 'archivos' END,
        miles(v_vis), CASE WHEN v_vis = 1 THEN 'registro' ELSE 'registros' END);

    -- Ventas y compras por separado. El caso de cero se dice con todas las
    -- letras porque es el que invalida medio informe.
    IF v_ventas = 0 THEN
        v_lineas := v_lineas ||
          '⚠️ <b>No tengo ninguna venta tuya.</b> Sin ventas no puedo calcular '
          'margen, rotación ni qué te deja plata: esto es solo lo que se ve '
          'desde tus compras.'::text;
    ELSIF v_compras = 0 THEN
        v_lineas := v_lineas ||
          '⚠️ <b>No tengo ninguna compra tuya.</b> Sin compras no puedo calcular '
          'margen ni costos: esto es solo lo que se ve desde tus ventas.'::text;
    ELSE
        v_lineas := v_lineas || format('🧾 %s de venta · %s de compra.',
            miles(v_ventas), miles(v_compras));
    END IF;

    -- Lo que está guardado y el plan no deja mirar. Decirlo es la diferencia
    -- entre "no tengo tus datos" y "tengo tus datos y te muestro esta parte".
    IF v_ocultos > 0 THEN
        v_lineas := v_lineas || format(
          '🔒 Tengo <b>%s</b> registros más guardados, fuera de la ventana de tu '
          'plan. No los perdés: mirá /plan.', miles(v_ocultos));
    END IF;

    SELECT (nullif(btrim(coalesce(n.nit, '')), '') IS NULL
            AND EXISTS (SELECT 1 FROM facturas f WHERE f.negocio_id = n.id))
      INTO v_sin_nit
    FROM negocios n WHERE n.id = v_neg;

    IF coalesce(v_sin_nit, false) THEN
        v_lineas := v_lineas ||
          '💡 Tus facturas las tomé todas como compras porque no tengo el NIT de '
          'tu negocio. Cargalo en /portal y voy a saber cuáles son ventas tuyas.'::text;
    END IF;

    RETURN replace(
             plantilla_cuerpo_srv('informe.base', p_servicio,
               E'🧮 <b>Sobre qué calculé esto</b>\n{{lineas}}'),
             '{{lineas}}', array_to_string(v_lineas, E'\n'));
END;
$$;



CREATE FUNCTION public.informe_estructura_seca(p_hallazgos jsonb, p_servicio text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_h    jsonb := coalesce(p_hallazgos, '{}'::jsonb);
    v_sec  jsonb := '[]'::jsonb;
    v_hall jsonb := '[]'::jsonb;
    v_pts  jsonb;
BEGIN
    IF jsonb_typeof(v_h -> 'recomendaciones') = 'array'
       AND jsonb_array_length(v_h -> 'recomendaciones') > 0 THEN
        SELECT jsonb_agg(jsonb_build_object(
                 'icono', e ->> 'icono', 'titulo', e ->> 'titulo',
                 'problema', e ->> 'problema', 'impacto', e ->> 'impacto',
                 'opciones', coalesce(e -> 'opciones', '[]'::jsonb),
                 'prioridad', e ->> 'prioridad'))
          INTO v_hall
        FROM (SELECT e FROM jsonb_array_elements(v_h -> 'recomendaciones') e LIMIT 5) s;

        RETURN jsonb_build_object(
            'titular', plantilla_cuerpo_srv('informe.titular_seco', p_servicio,
                         'Esto es lo que encontré en tus números'),
            'hallazgos', coalesce(v_hall, '[]'::jsonb),
            'secciones', '[]'::jsonb,
            'acciones',  '[]'::jsonb,
            'narrado',   false);
    END IF;

    -- Las cifras se copian tal cual del JSON de hallazgos, sin reformatear: son
    -- exactamente las que validar_cifras daría por buenas.
    IF jsonb_typeof(v_h -> 'hechos') = 'array'
       AND jsonb_array_length(v_h -> 'hechos') > 0 THEN
        SELECT jsonb_agg(btrim(coalesce(nullif(e ->> 'contenido', ''), e ->> 'titulo')))
          INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(v_h -> 'hechos') e LIMIT 3) s;

        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '🔎', 'titulo', 'Lo que tengo cargado', 'puntos', v_pts));
        END IF;
    ELSE
        SELECT jsonb_agg(format('%s: deja %s%% de margen',
                                e ->> 'producto', e ->> 'margen_pct')) INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(coalesce(v_h->'margen_bajo','[]'::jsonb)) e
              LIMIT 3) s;
        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '⚠️', 'titulo', 'Margen bajo', 'puntos', v_pts));
        END IF;

        SELECT jsonb_agg(format('%s: el costo se movió %s%%',
                                e ->> 'producto', e ->> 'deriva_pct')) INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(coalesce(v_h->'deriva_costo','[]'::jsonb)) e
              LIMIT 3) s;
        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '📈', 'titulo', 'Les subió el costo', 'puntos', v_pts));
        END IF;

        SELECT jsonb_agg(format('%s: alcanza para %s días',
                                e ->> 'producto', e ->> 'dias_cobertura')) INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(coalesce(v_h->'baja_cobertura','[]'::jsonb)) e
              LIMIT 3) s;
        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '🕐', 'titulo', 'Se agotan pronto', 'puntos', v_pts));
        END IF;

        SELECT jsonb_agg(format('%s: aporta %s%% de la utilidad',
                                e ->> 'producto', e ->> 'pct_utilidad')) INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(coalesce(v_h->'pareto','[]'::jsonb)) e
              LIMIT 3) s;
        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '🏆', 'titulo', 'Concentran la ganancia', 'puntos', v_pts));
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'titular', plantilla_cuerpo_srv('informe.titular_seco', p_servicio,
                     'Esto es lo que encontré en tus números'),
        'secciones', v_sec,
        'acciones', '[]'::jsonb,
        'narrado', false);
END;
$$;



CREATE FUNCTION public.informe_render(p_estructura jsonb, p_hallazgos jsonb, p_servicio text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql STABLE
    AS $$

DECLARE
    v_iconos_ok text[] := ARRAY['⚠️','📈','📉','📦','💰','🏆','🔎','🧾','🕐','✅'];
    v_bloques   text[] := '{}';
    v_metricas  text[] := '{}';
    v_partes    text[];
    v_puntos    text[];
    v_enc       jsonb;
    v_sec       jsonb;
    v_pt        text;
    v_icono     text;
    v_titular   text;
    v_nombre    text;
    v_subtitulo text;
    v_margen    text;
    v_prio      text;
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

    -- --- Salud del negocio (de la base, no del modelo) ----------------------
    v_tmp := informe_salud_bloque(p_hallazgos -> 'salud', p_servicio);
    IF v_tmp IS NOT NULL THEN
        v_bloques := v_bloques || v_tmp;
    END IF;

    -- --- De qué datos habla este informe (072) ------------------------------
    -- Va DESPUÉS de la salud y ANTES del titular a propósito: el usuario tiene
    -- que saber sobre qué se calculó el semáforo antes de leer una conclusión.
    v_tmp := informe_base_bloque(p_hallazgos, p_servicio);
    IF v_tmp IS NOT NULL THEN
        v_bloques := v_bloques || v_tmp;
    END IF;

    -- --- Titular ------------------------------------------------------------
    v_bloques := v_bloques || replace(
        plantilla_cuerpo_srv('informe.titular', p_servicio, '<b>{{titular}}</b>'),
        '{{titular}}', esc_html(v_titular));

    -- --- Hallazgos prescriptivos --------------------------------------------
    IF jsonb_typeof(p_estructura -> 'hallazgos') = 'array' THEN
        FOR v_sec IN SELECT * FROM jsonb_array_elements(p_estructura -> 'hallazgos') LOOP
            CONTINUE WHEN jsonb_typeof(v_sec) <> 'object';
            CONTINUE WHEN coalesce(v_sec ->> 'titulo', '') = '';

            v_icono := v_sec ->> 'icono';
            IF v_icono IS NULL OR NOT (v_icono = ANY(v_iconos_ok)) THEN
                v_icono := '🔎';
            END IF;

            v_partes := ARRAY[ replace(replace(
                plantilla_cuerpo_srv('informe.hallazgo_titulo', p_servicio,
                    '{{icono}} <b>{{titulo}}</b>'),
                '{{icono}}',  v_icono),
                '{{titulo}}', esc_html(limpiar_marcado(v_sec ->> 'titulo'))) ];

            IF coalesce(btrim(v_sec ->> 'problema'), '') <> '' THEN
                v_partes := v_partes || replace(
                    plantilla_cuerpo_srv('informe.hallazgo_problema', p_servicio, '{{texto}}'),
                    '{{texto}}', esc_html(limpiar_marcado(v_sec ->> 'problema')));
            END IF;

            IF coalesce(btrim(v_sec ->> 'impacto'), '') <> '' THEN
                v_partes := v_partes || replace(
                    plantilla_cuerpo_srv('informe.hallazgo_impacto', p_servicio,
                        '💸 <b>{{texto}}</b>'),
                    '{{texto}}', esc_html(limpiar_marcado(v_sec ->> 'impacto')));
            END IF;

            IF jsonb_typeof(v_sec -> 'opciones') = 'array' THEN
                FOR v_pt IN SELECT * FROM jsonb_array_elements_text(v_sec -> 'opciones') LOOP
                    CONTINUE WHEN coalesce(btrim(v_pt), '') = '';
                    v_partes := v_partes || replace(
                        plantilla_cuerpo_srv('informe.opcion', p_servicio, '✓ {{texto}}'),
                        '{{texto}}', esc_html(limpiar_marcado(v_pt)));
                END LOOP;
            END IF;

            -- La prioridad del modelo solo se acepta si es una de las tres.
            v_prio := lower(coalesce(v_sec ->> 'prioridad', ''));
            IF v_prio IN ('alta','media','baja') THEN
                v_partes := v_partes || replace(replace(
                    plantilla_cuerpo_srv('informe.hallazgo_prioridad', p_servicio,
                        '{{semaforo}} Prioridad {{nivel}}'),
                    '{{semaforo}}', CASE v_prio WHEN 'alta' THEN '🔴'
                                                WHEN 'media' THEN '🟡' ELSE '🟢' END),
                    '{{nivel}}', v_prio);
            END IF;

            v_bloques := v_bloques || array_to_string(v_partes, E'\n');
        END LOOP;
    END IF;

    -- --- Secciones (forma clásica; la usan los servicios sin motor de reglas) -
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

    RETURN array_to_string(array_remove(v_bloques, ''), E'\n\n');
END;
$$;



CREATE FUNCTION public.informe_salud_bloque(p_salud jsonb, p_servicio text) RETURNS text
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_lineas text[] := '{}';
    v_tmp    text;
    v_clave  text;
    v_eti    text;
    v_val    numeric;
BEGIN
    IF p_salud IS NULL OR jsonb_typeof(p_salud) <> 'object'
       OR p_salud -> 'indice' IS NULL THEN
        RETURN NULL;
    END IF;

    v_tmp := plantilla_cuerpo_srv('informe.salud_linea', p_servicio,
               '{{semaforo}} {{etiqueta}} <code>{{barra}}</code> {{valor}}');

    FOR v_clave, v_eti IN
        SELECT * FROM (VALUES ('ventas','Ventas    '), ('margenes','Márgenes  '),
                              ('inventario','Inventario'), ('compras','Compras   '),
                              ('riesgos','Riesgos   ')) AS t(c, e)
    LOOP
        CONTINUE WHEN p_salud -> v_clave IS NULL;
        v_val := (p_salud ->> v_clave)::numeric;
        -- >>> 054: la nota de inventario calculada sobre stock sin conteo
        -- lleva una marca. No se oculta la nota —sería peor— pero tampoco
        -- se presenta como si el stock fuera un dato conocido.
        v_lineas := v_lineas || replace(replace(replace(replace(v_tmp,
            '{{semaforo}}', semaforo(v_val)),
            '{{etiqueta}}', esc_html(v_eti)),
            '{{barra}}',    barra_10(v_val)),
            '{{valor}}',    lpad(v_val::int::text, 3, ' ')
              || CASE WHEN v_clave = 'inventario'
                       AND (p_salud ->> 'inventario_estimado')::boolean
                      THEN ' *' ELSE '' END);
    END LOOP;

    IF cardinality(v_lineas) = 0 THEN
        RETURN NULL;
    END IF;

    -- La nota al pie solo aparece si hubo algo que marcar.
    IF coalesce((p_salud ->> 'inventario_estimado')::boolean, false)
       AND p_salud -> 'inventario' IS NOT NULL THEN
        -- array_append y no `||`: con un literal sin tipo, `text[] || '...'`
        -- resuelve a array_cat e intenta leer la frase como un array.
        v_lineas := array_append(v_lineas,
            E'\n<i>* Inventario estimado: es lo que compraste menos lo que vendiste. Pasame un conteo y la nota se calcula sobre tu stock real.</i>');
    END IF;

    RETURN replace(replace(
        plantilla_cuerpo_srv('informe.salud', p_servicio,
            E'🩺 <b>Salud del negocio</b>\n{{lineas}}\n\n<b>Índice general: {{indice}}/100</b>'),
        '{{lineas}}', array_to_string(v_lineas, E'\n')),
        '{{indice}}', (p_salud ->> 'indice'));
END;
$$;



CREATE FUNCTION public.informes_periodicos_disparar() RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_desde int  := coalesce((parametro(NULL,'alerta_hora_desde'))::text::int, 8);
    v_hasta int  := coalesce((parametro(NULL,'alerta_hora_hasta'))::text::int, 20);
    v_tz    text := coalesce(btrim((parametro(NULL,'zona_horaria'))::text, '"'),
                             'America/Bogota');
    v_srv   text;
    v_hora  int;
    v_notif jsonb := '[]'::jsonb;
    v_ejecs jsonb := '[]'::jsonb;
    v_ses   bigint;
    v_ejec  bigint;
    n       record;
BEGIN
    IF coalesce((parametro(NULL,'informe_periodico_activo'))::text::boolean, true) = false THEN
        RETURN jsonb_build_object('notificaciones', '[]'::jsonb,
                                  'ejecuciones', '[]'::jsonb, 'apagado', true);
    END IF;

    v_hora := extract(hour FROM (now() AT TIME ZONE v_tz))::int;
    IF v_hora < v_desde OR v_hora >= v_hasta THEN
        RETURN jsonb_build_object('notificaciones', '[]'::jsonb,
                                  'ejecuciones', '[]'::jsonb,
                                  'fuera_de_horario', true);
    END IF;

    SELECT codigo INTO v_srv FROM servicios
    WHERE activo AND entrada = 'archivos' ORDER BY orden LIMIT 1;
    IF v_srv IS NULL THEN
        RETURN jsonb_build_object('notificaciones', '[]'::jsonb,
                                  'ejecuciones', '[]'::jsonb);
    END IF;

    FOR n IN SELECT * FROM v_negocios_informe_periodico LOOP
        INSERT INTO sesiones (usuario_id, negocio_id, servicio_codigo, estado, paso, contexto)
        VALUES (n.usuario_id, n.negocio_id, v_srv, 'procesando', 'ejecutando',
                jsonb_build_object('origen', 'periodico'))
        RETURNING id INTO v_ses;

        INSERT INTO ejecuciones (sesion_id, negocio_id, servicio_codigo, estado)
        VALUES (v_ses, n.negocio_id, v_srv, 'preparando')
        RETURNING id INTO v_ejec;

        -- El aviso va ANTES. Un informe que aparece sin explicación se lee como
        -- spam por bueno que sea, y encima el dueño no sabe por qué le llegó.
        v_notif := v_notif || jsonb_build_array(jsonb_build_object(
          'chat_id', n.chat_id,
          'respuestas', jsonb_build_array(jsonb_build_object(
            'plantilla', 'informe.periodico_aviso',
            'vars', jsonb_build_object('movimientos', n.movs_nuevos)))));

        v_ejecs := v_ejecs || jsonb_build_array(
                     jsonb_build_object('tipo', 'ejecutar', 'ejecucion_id', v_ejec));
    END LOOP;

    RETURN jsonb_build_object('notificaciones', v_notif, 'ejecuciones', v_ejecs);
END;
$$;



CREATE FUNCTION public.ingesta_cargar_inventario(p_documento_id bigint, p_filas jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_negocio_id bigint;
    v_mapeo      jsonb;
    v_cols       jsonb;
    v_dec        text;
    v_mil        text;
    v_fmt        text;
    v_estado     estado_doc;
    v_error      text;
    v_n          int := 0;
    v_sin_prod   int := 0;
BEGIN
    SELECT d.estado, d.error, d.negocio_id, f.mapeo
      INTO v_estado, v_error, v_negocio_id, v_mapeo
    FROM documentos d
    LEFT JOIN formatos_documento f ON f.codigo = d.formato_codigo
    WHERE d.id = p_documento_id;

    IF v_estado = 'error' THEN
        RETURN jsonb_build_object('documento_id', p_documento_id,
                                  'estado', 'error', 'error', v_error);
    END IF;
    IF v_mapeo IS NULL THEN
        RETURN ingesta_marcar_error(p_documento_id, 'el documento no tiene formato asignado');
    END IF;

    v_cols := v_mapeo -> 'columnas';
    v_dec  := coalesce(v_mapeo ->> 'decimal', '.');
    v_mil  := coalesce(v_mapeo ->> 'miles', '');
    v_fmt  := v_mapeo ->> 'formato_fecha';

    WITH filas AS (
        SELECT ingesta_fecha(r -> (v_cols ->> 'fecha'), v_fmt)                 AS fecha,
               btrim(coalesce(r ->> (v_cols ->> 'producto'), ''))              AS producto_txt,
               ingesta_num  (r -> (v_cols ->> 'unidades'), v_dec, v_mil)       AS unidades
        FROM jsonb_array_elements(coalesce(p_filas, '[]'::jsonb)) AS r
    ),
    resueltas AS (
        -- Un conteo sin fecha legible es un conteo de hoy: es lo que acaba de
        -- hacer quien mandó el archivo. Pero `to_date` es indulgente y con un
        -- patrón mal declarado devuelve basura en vez de fallar (14/08/2026 con
        -- 'YYYY-MM-DD' da 2008-01-01), así que lo absurdo se descarta antes de
        -- caer al default en vez de guardarse como si fuera un dato.
        SELECT coalesce(CASE WHEN fecha BETWEEN date '2000-01-01' AND current_date + 1
                             THEN fecha END, current_date) AS fecha,
               producto_txt, unidades,
               (match_resolver_producto(v_negocio_id, producto_txt) ->> 'producto_id')::bigint AS producto_id
        FROM filas
        WHERE nullif(producto_txt, '') IS NOT NULL AND unidades IS NOT NULL
    ),
    ins AS (
        INSERT INTO conteos_inventario
               (negocio_id, producto_id, fecha, unidades, origen, documento_id)
        SELECT v_negocio_id, producto_id, fecha, unidades, 'archivo', p_documento_id
        FROM resueltas WHERE producto_id IS NOT NULL
        ON CONFLICT (negocio_id, producto_id, fecha)
          DO UPDATE SET unidades = EXCLUDED.unidades,
                        origen   = EXCLUDED.origen,
                        documento_id = EXCLUDED.documento_id
        RETURNING 1
    )
    SELECT (SELECT count(*) FROM ins),
           (SELECT count(*) FROM resueltas WHERE producto_id IS NULL)
      INTO v_n, v_sin_prod;

    UPDATE documentos SET estado = 'parseado', error = NULL WHERE id = p_documento_id;

    RETURN jsonb_build_object('documento_id', p_documento_id, 'estado', 'parseado',
                              'clase', 'inventario', 'conteos', v_n,
                              'sin_producto', v_sin_prod);
END;
$$;



CREATE FUNCTION public.ingesta_cargar_tabular(p_documento_id bigint, p_filas jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_mapeo jsonb;
BEGIN
    SELECT f.mapeo INTO v_mapeo
    FROM documentos d JOIN formatos_documento f ON f.codigo = d.formato_codigo
    WHERE d.id = p_documento_id;

    IF coalesce((v_mapeo ->> 'agregado')::boolean, false) THEN
        RETURN ingesta_marcar_error(p_documento_id,
                 'es un resumen (totales por día, sin producto ni cantidad), '
                 'no un detalle de movimientos: sumarlo contaría dos veces lo '
                 'que ya traen los archivos de detalle')
               || jsonb_build_object('agregado', true);
    END IF;

    RETURN ingesta_cargar_tabular_detalle(p_documento_id, p_filas);
END;
$$;



CREATE FUNCTION public.ingesta_cargar_tabular_detalle(p_documento_id bigint, p_filas jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_negocio_id bigint;
    v_mapeo      jsonb;
    v_cols       jsonb;
    v_tipo       text;
    v_dec        text;
    v_mil        text;
    v_fmt        text;
    v_max_nulos  numeric;
    v_estado     estado_doc;
    v_error      text;
    v_n          int;
    v_sin_fecha  int;
    v_sin_valor  int;
    v_pct_fecha  numeric;
    v_pct_valor  numeric;
BEGIN
    SELECT d.estado, d.error, d.negocio_id, f.mapeo
      INTO v_estado, v_error, v_negocio_id, v_mapeo
    FROM documentos d
    LEFT JOIN formatos_documento f ON f.codigo = d.formato_codigo
    WHERE d.id = p_documento_id;

    -- Ya venía marcado en error por un paso anterior: se respeta el motivo.
    IF v_estado = 'error' THEN
        RETURN jsonb_build_object('documento_id', p_documento_id,
                                  'estado', 'error', 'error', v_error);
    END IF;

    IF v_mapeo IS NULL THEN
        RETURN ingesta_marcar_error(p_documento_id, 'el documento no tiene formato asignado');
    END IF;

    v_cols      := v_mapeo -> 'columnas';
    v_tipo      := coalesce(v_mapeo ->> 'tipo', 'venta');
    v_dec       := coalesce(v_mapeo ->> 'decimal', '.');
    v_mil       := coalesce(v_mapeo ->> 'miles', '');
    v_fmt       := v_mapeo ->> 'formato_fecha';
    v_max_nulos := coalesce((v_mapeo ->> 'max_pct_nulos')::numeric, 20);

    WITH norm AS (
        SELECT ingesta_fecha(r -> (v_cols ->> 'fecha'), v_fmt)                  AS fecha,
               ingesta_num  (r -> (v_cols ->> 'cantidad'),       v_dec, v_mil)  AS cantidad,
               ingesta_num  (r -> (v_cols ->> 'valor_unitario'), v_dec, v_mil)  AS valor_unitario,
               ingesta_num  (r -> (v_cols ->> 'valor_total'),    v_dec, v_mil)  AS valor_total,
               r || jsonb_strip_nulls(jsonb_build_object(
                      'producto',  r ->> (v_cols ->> 'producto'),
                      'categoria', r ->> (v_cols ->> 'categoria'),
                      'codigo',    r ->> (v_cols ->> 'codigo'),
                      'unidad',    r ->> (v_cols ->> 'unidad')))                AS raw
        FROM jsonb_array_elements(coalesce(p_filas, '[]'::jsonb)) AS r
    ),
    medida AS (
        SELECT count(*)::int                                          AS n,
               count(*) FILTER (WHERE fecha IS NULL)::int             AS sin_fecha,
               count(*) FILTER (WHERE valor_total IS NULL
                                  AND valor_unitario IS NULL)::int    AS sin_valor
        FROM norm
    ),
    compuerta AS (
        SELECT n, sin_fecha, sin_valor,
               round(sin_fecha * 100.0 / greatest(n,1), 1) AS pct_fecha,
               round(sin_valor * 100.0 / greatest(n,1), 1) AS pct_valor,
               n > 0
                 AND round(sin_fecha * 100.0 / greatest(n,1), 1) <= v_max_nulos
                 AND round(sin_valor * 100.0 / greatest(n,1), 1) <= v_max_nulos AS pasa
        FROM medida
    ),
    ins AS (
        INSERT INTO movimientos (negocio_id, documento_id, tipo, fecha,
                                 cantidad, valor_unitario, valor_total, raw)
        SELECT v_negocio_id, p_documento_id, v_tipo::tipo_movimiento,
               nm.fecha, nm.cantidad,
               coalesce(nm.valor_unitario,
                        CASE WHEN nm.cantidad > 0 THEN nm.valor_total / nm.cantidad END),
               coalesce(nm.valor_total, nm.valor_unitario * nm.cantidad),
               nm.raw
        FROM norm nm CROSS JOIN compuerta c
        WHERE c.pasa
        RETURNING 1
    )
    SELECT n, sin_fecha, sin_valor, pct_fecha, pct_valor
      INTO v_n, v_sin_fecha, v_sin_valor, v_pct_fecha, v_pct_valor
    FROM compuerta;

    IF v_n = 0 THEN
        RETURN ingesta_marcar_error(p_documento_id, 'el archivo no tiene filas de datos');
    END IF;

    IF v_pct_fecha > v_max_nulos THEN
        RETURN ingesta_marcar_error(p_documento_id,
                 format('no pude leer la fecha en %s%% de las %s filas (columna "%s", formato %s)',
                        v_pct_fecha, v_n, coalesce(v_cols ->> 'fecha','?'),
                        coalesce(v_fmt,'sin declarar')))
               || jsonb_build_object('filas', v_n, 'pct_sin_fecha', v_pct_fecha);
    END IF;

    IF v_pct_valor > v_max_nulos THEN
        RETURN ingesta_marcar_error(p_documento_id,
                 format('no pude leer el valor en %s%% de las %s filas (columnas "%s"/"%s", decimal "%s")',
                        v_pct_valor, v_n, coalesce(v_cols ->> 'valor_total','?'),
                        coalesce(v_cols ->> 'valor_unitario','?'), v_dec))
               || jsonb_build_object('filas', v_n, 'pct_sin_valor', v_pct_valor);
    END IF;

    UPDATE documentos SET estado = 'parseado', error = NULL WHERE id = p_documento_id;

    RETURN jsonb_build_object('documento_id', p_documento_id, 'estado', 'parseado',
                              'filas', v_n, 'tipo', v_tipo,
                              'pct_sin_fecha', v_pct_fecha,
                              'pct_sin_valor', v_pct_valor);
END;
$$;



CREATE FUNCTION public.ingesta_es_agregado(p_columnas jsonb) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT (p_columnas ? 'valor_total' OR p_columnas ? 'valor_unitario')
       AND NOT (p_columnas ? 'producto')
       AND NOT (p_columnas ? 'cantidad');
$$;



CREATE FUNCTION public.ingesta_fecha(p_valor jsonb, p_formato text DEFAULT NULL::text) RETURNS date
    LANGUAGE plpgsql IMMUTABLE
    AS $_$
DECLARE
    v_txt text;
    v_n   numeric;
BEGIN
    IF p_valor IS NULL OR jsonb_typeof(p_valor) IN ('null','object','array') THEN
        RETURN NULL;
    END IF;

    -- Serial de Excel: los xlsx sin cellDates traen 46000 en vez de una fecha.
    -- La época de Excel es 1899-12-30 por su bug del año bisiesto de 1900.
    IF jsonb_typeof(p_valor) = 'number' THEN
        v_n := (p_valor #>> '{}')::numeric;
        IF v_n BETWEEN 20000 AND 80000 THEN
            RETURN date '1899-12-30' + (floor(v_n))::int;
        END IF;
        RETURN NULL;
    END IF;

    v_txt := btrim(p_valor #>> '{}');
    IF v_txt = '' THEN RETURN NULL; END IF;
    -- Recorta la parte de hora si viene (ISO o "12/03/2026 14:22").
    v_txt := split_part(split_part(v_txt, 'T', 1), ' ', 1);

    IF coalesce(p_formato, '') <> '' THEN
        RETURN to_date(v_txt, p_formato);
    END IF;

    -- Sin formato declarado solo se acepta ISO. dd/mm y mm/dd son
    -- indistinguibles y adivinar fue justo el bug de este archivo: mejor NULL
    -- y que la compuerta obligue a declarar formato_fecha en el mapeo.
    IF v_txt ~ '^\d{4}-\d{2}-\d{2}$' THEN
        RETURN v_txt::date;
    END IF;
    RETURN NULL;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$_$;



CREATE FUNCTION public.ingesta_huella(p_columnas text[]) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT md5(string_agg(c, '|' ORDER BY c))
    FROM (SELECT DISTINCT norm_texto(unnest) AS c
          FROM unnest(p_columnas)
          WHERE btrim(coalesce(unnest,'')) <> '') s;
$$;



CREATE FUNCTION public.ingesta_identificar_tabular(p_documento_id bigint, p_columnas text[]) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_huella  text := ingesta_huella(p_columnas);
    v_formato text;
BEGIN
    IF v_huella IS NULL THEN
        RETURN ingesta_marcar_error(p_documento_id,
                 'el archivo no tiene cabeceras legibles')
               || jsonb_build_object('requiere_inferencia', false);
    END IF;

    SELECT codigo INTO v_formato FROM formatos_documento
    WHERE activo AND clase = 'tabular' AND huella = v_huella;

    IF v_formato IS NOT NULL THEN
        UPDATE documentos SET formato_codigo = v_formato WHERE id = p_documento_id;
        RETURN jsonb_build_object('documento_id', p_documento_id,
                                  'formato', v_formato, 'huella', v_huella,
                                  'requiere_inferencia', false);
    END IF;

    RETURN jsonb_build_object('documento_id', p_documento_id, 'huella', v_huella,
                              'columnas', to_jsonb(p_columnas),
                              'requiere_inferencia', true);
END;
$$;



CREATE FUNCTION public.ingesta_identificar_tabular(p_documento_id bigint, p_columnas text[], p_muestra jsonb DEFAULT '[]'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_huella  text := ingesta_huella(p_columnas);
    v_formato text;
    v_sql     jsonb;
    v_reg     jsonb;
BEGIN
    IF v_huella IS NULL THEN
        RETURN ingesta_marcar_error(p_documento_id,
                 'el archivo no tiene cabeceras legibles')
               || jsonb_build_object('requiere_inferencia', false);
    END IF;

    -- (a) Ya la conocemos: cero trabajo.
    SELECT codigo INTO v_formato FROM formatos_documento
    WHERE activo AND clase = 'tabular' AND huella = v_huella;

    IF v_formato IS NOT NULL THEN
        UPDATE documentos SET formato_codigo = v_formato WHERE id = p_documento_id;
        RETURN jsonb_build_object('documento_id', p_documento_id,
                                  'formato', v_formato, 'huella', v_huella,
                                  'origen', 'cache',
                                  'requiere_inferencia', false);
    END IF;

    -- (b) Huella nueva: el diccionario antes que el modelo.
    v_sql := ingesta_inferir_mapeo_sql(p_documento_id, p_columnas, p_muestra);

    IF coalesce((v_sql ->> 'resuelto')::boolean, false) THEN
        v_reg := ingesta_registrar_formato_resuelto(p_documento_id, p_columnas, v_sql);
        RETURN v_reg || jsonb_build_object('huella', v_huella,
                                           'mapeo', v_sql,
                                           'requiere_inferencia', false);
    END IF;

    -- (c) Recién acá se gasta una llamada.
    RETURN jsonb_build_object('documento_id', p_documento_id, 'huella', v_huella,
                              'columnas', to_jsonb(p_columnas),
                              'motivo_inferencia', v_sql ->> 'motivo',
                              'requiere_inferencia', true);
END;
$$;



CREATE FUNCTION public.ingesta_inferir_decimales(p_muestra jsonb, p_columnas jsonb) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE
    AS $_$
DECLARE
    v_vals   text[] := '{}';
    v_clave  text;
    v_col    text;
    v_fila   jsonb;
    v_txt    text;
BEGIN
    -- Solo los valores de las columnas numéricas: una descripción con comas
    -- no tiene por qué opinar sobre el separador decimal.
    FOREACH v_clave IN ARRAY ARRAY['cantidad','valor_unitario','valor_total','impuesto'] LOOP
        v_col := p_columnas ->> v_clave;
        CONTINUE WHEN v_col IS NULL;
        FOR v_fila IN SELECT * FROM jsonb_array_elements(coalesce(p_muestra,'[]'::jsonb)) LOOP
            v_txt := btrim(coalesce(v_fila ->> v_col, ''));
            IF v_txt <> '' THEN v_vals := v_vals || v_txt; END IF;
        END LOOP;
    END LOOP;

    -- 1.234,56 -> miles '.', decimal ','
    IF EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v ~ '^-?\d{1,3}(\.\d{3})+,\d+$') THEN
        RETURN jsonb_build_object('decimal', ',', 'miles', '.');
    END IF;
    -- 1,234.56 -> miles ',', decimal '.'
    IF EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v ~ '^-?\d{1,3}(,\d{3})+\.\d+$') THEN
        RETURN jsonb_build_object('decimal', '.', 'miles', ',');
    END IF;
    -- 1.234.567 sin decimales -> el punto es de miles
    IF EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v ~ '^-?\d{1,3}(\.\d{3})+$')
       AND NOT EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v ~ '^-?\d+\.\d{1,2}$') THEN
        RETURN jsonb_build_object('decimal', ',', 'miles', '.');
    END IF;
    -- 1234,56 sin separador de miles
    IF EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v ~ '^-?\d+,\d{1,2}$')
       AND NOT EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v ~ '^-?\d+\.\d+$') THEN
        RETURN jsonb_build_object('decimal', ',', 'miles', '');
    END IF;

    RETURN jsonb_build_object('decimal', '.', 'miles', '');
END;
$_$;



CREATE FUNCTION public.ingesta_inferir_formato_fecha(p_muestra jsonb, p_columna text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    AS $_$
DECLARE
    v_vals text[] := '{}';
    v_fila jsonb;
    v_txt  text;
    v_sep  text;
    v_a    int;
    v_b    int;
BEGIN
    IF p_columna IS NULL THEN RETURN NULL; END IF;

    FOR v_fila IN SELECT * FROM jsonb_array_elements(coalesce(p_muestra,'[]'::jsonb)) LOOP
        v_txt := btrim(coalesce(v_fila ->> p_columna, ''));
        -- Se recorta la hora igual que ingesta_fecha, para comparar lo mismo.
        v_txt := split_part(split_part(v_txt, 'T', 1), ' ', 1);
        IF v_txt <> '' THEN v_vals := v_vals || v_txt; END IF;
    END LOOP;

    IF cardinality(v_vals) = 0 THEN RETURN NULL; END IF;

    -- ISO: sin ambigüedad posible.
    IF NOT EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v !~ '^\d{4}-\d{2}-\d{2}$') THEN
        RETURN 'YYYY-MM-DD';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v !~ '^\d{4}/\d{2}/\d{2}$') THEN
        RETURN 'YYYY/MM/DD';
    END IF;

    -- dd?s?mm?s?yyyy: hay que decidir cuál de los dos primeros es el día.
    IF NOT EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v !~ '^\d{1,2}[/-]\d{1,2}[/-]\d{4}$') THEN
        v_sep := CASE WHEN v_vals[1] ~ '-' THEN '-' ELSE '/' END;
        SELECT max(split_part(v, v_sep, 1)::int), max(split_part(v, v_sep, 2)::int)
          INTO v_a, v_b FROM unnest(v_vals) v;
        -- Un primer componente > 12 solo puede ser un día.
        IF v_a > 12 THEN RETURN 'DD' || v_sep || 'MM' || v_sep || 'YYYY'; END IF;
        -- Un segundo componente > 12 solo puede ser un día.
        IF v_b > 12 THEN RETURN 'MM' || v_sep || 'DD' || v_sep || 'YYYY'; END IF;
        -- Ambiguo de verdad: comercio latinoamericano, DD/MM. Es la misma
        -- convención que ya declara el prompt del modelo.
        RETURN 'DD' || v_sep || 'MM' || v_sep || 'YYYY';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v !~ '^\d{1,2}[/-]\d{1,2}[/-]\d{2}$') THEN
        v_sep := CASE WHEN v_vals[1] ~ '-' THEN '-' ELSE '/' END;
        SELECT max(split_part(v, v_sep, 1)::int) INTO v_a FROM unnest(v_vals) v;
        IF v_a > 12 THEN RETURN 'DD' || v_sep || 'MM' || v_sep || 'YY'; END IF;
        RETURN 'DD' || v_sep || 'MM' || v_sep || 'YY';
    END IF;

    -- Serial de Excel u otra cosa: NULL y que decida ingesta_fecha, que ya sabe
    -- convertir el serial y devolver NULL en vez de un dato equivocado.
    RETURN NULL;
END;
$_$;



CREATE FUNCTION public.ingesta_inferir_mapeo_sql(p_documento_id bigint, p_columnas text[], p_muestra jsonb DEFAULT '[]'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_cols  jsonb := ingesta_resolver_columnas(p_columnas);
    v_dec   jsonb := ingesta_inferir_decimales(p_muestra, v_cols);
    v_fmt   text;
    v_tiene_valor boolean;
BEGIN
    v_fmt := ingesta_inferir_formato_fecha(p_muestra, v_cols ->> 'fecha');
    v_tiene_valor := (v_cols ? 'valor_total') OR (v_cols ? 'valor_unitario');

    -- Sin fecha o sin plata no hay nada que cargar. Puede ser que las columnas
    -- se llamen de un modo que el diccionario no cubre todavía: ahí sí vale
    -- gastar la llamada al modelo.
    IF NOT (v_cols ? 'fecha') OR NOT v_tiene_valor THEN
        RETURN jsonb_build_object(
            'resuelto', false,
            'motivo',   CASE WHEN NOT (v_cols ? 'fecha')
                             THEN 'no reconocí la columna de fecha'
                             ELSE 'no reconocí la columna de valor' END,
            'columnas', v_cols);
    END IF;

    RETURN jsonb_build_object(
        'resuelto',      true,
        'agregado',      ingesta_es_agregado(v_cols),
        'tipo',          ingesta_inferir_tipo(p_documento_id, p_columnas),
        'decimal',       v_dec ->> 'decimal',
        'miles',         v_dec ->> 'miles',
        'formato_fecha', v_fmt,
        'columnas',      v_cols);
END;
$$;



CREATE FUNCTION public.ingesta_inferir_tipo(p_documento_id bigint, p_columnas text[]) RETURNS text
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_nombre text;
    v_cols   text;
BEGIN
    SELECT norm_texto(nombre_archivo) INTO v_nombre
    FROM documentos WHERE id = p_documento_id;

    IF coalesce(v_nombre,'') ~ '(compra|proveedor|entrada|abastec|surtido|pedido)' THEN
        RETURN 'compra';
    END IF;
    IF coalesce(v_nombre,'') ~ '(venta|salida|pos|caja|factura|ticket)' THEN
        RETURN 'venta';
    END IF;

    SELECT norm_texto(string_agg(c, ' ')) INTO v_cols FROM unnest(p_columnas) c;
    IF coalesce(v_cols,'') ~ '(proveedor|nit[ _]?prov|razon[ _]?social)' THEN
        RETURN 'compra';
    END IF;

    RETURN 'venta';
END;
$$;



CREATE FUNCTION public.ingesta_marcar_error(p_documento_id bigint, p_error text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE documentos SET estado = 'error', error = p_error WHERE id = p_documento_id;
    RETURN jsonb_build_object('documento_id', p_documento_id, 'estado', 'error', 'error', p_error);
END;
$$;



CREATE FUNCTION public.ingesta_num(p_valor jsonb, p_decimal text DEFAULT '.'::text, p_miles text DEFAULT ','::text) RETURNS numeric
    LANGUAGE plpgsql IMMUTABLE
    AS $_$
DECLARE
    v_txt text;
    v_neg boolean := false;
BEGIN
    IF p_valor IS NULL OR jsonb_typeof(p_valor) IN ('null','object','array') THEN
        RETURN NULL;
    END IF;

    -- Ya es número: no tocarlo.
    IF jsonb_typeof(p_valor) = 'number' THEN
        RETURN (p_valor #>> '{}')::numeric;
    END IF;

    v_txt := btrim(p_valor #>> '{}');
    IF v_txt = '' THEN RETURN NULL; END IF;

    -- Negativo contable: (1.234,50)
    IF v_txt ~ '^\(.*\)$' THEN
        v_neg := true;
        v_txt := btrim(v_txt, '()');
    END IF;
    IF v_txt ~ '^-' THEN v_neg := true; END IF;

    -- Primero los miles (se van), después la coma decimal pasa a punto.
    IF coalesce(p_miles, '') <> '' THEN
        v_txt := replace(v_txt, p_miles, '');
    END IF;
    IF coalesce(p_decimal, '.') <> '.' THEN
        v_txt := replace(v_txt, p_decimal, '.');
    END IF;

    -- Fuera símbolo de moneda, espacios (incluido el no-separable), letras.
    v_txt := regexp_replace(v_txt, '[^0-9.]', '', 'g');
    IF v_txt = '' OR v_txt = '.' THEN RETURN NULL; END IF;

    -- Un archivo mal declarado puede dejar varios puntos: no adivinar.
    IF length(v_txt) - length(replace(v_txt, '.', '')) > 1 THEN
        RETURN NULL;
    END IF;

    RETURN CASE WHEN v_neg THEN -v_txt::numeric ELSE v_txt::numeric END;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;   -- un valor ilegible es NULL, y la compuerta lo cuenta
END;
$_$;



CREATE FUNCTION public.ingesta_parsear_dian(p_documento_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $_$
DECLARE
    v_negocio_id bigint;
    v_xml        xml;
    v_raiz       text;
    v_linea_tag  text;
    v_num        text;
    v_fecha      date;
    v_proveedor  text;
    v_payable    numeric;
    v_impuesto   numeric;
    v_suma_lineas numeric;
    v_n_lineas   int;
    v_cartera    jsonb;
BEGIN
    SELECT negocio_id, convert_from(contenido, 'UTF8')::xml
      INTO v_negocio_id, v_xml
    FROM documentos WHERE id = p_documento_id;

    v_raiz := (xpath('local-name(/*)', v_xml))[1]::text;

    IF v_raiz = 'AttachedDocument' THEN
        v_xml := regexp_replace(
                   regexp_replace(
                     (xpath('//*[local-name()="Attachment"]//*[local-name()="Description"]/text()', v_xml))[1]::text,
                     '^\s*<!\[CDATA\[', ''),
                   '\]\]>\s*$', '')::xml;
        v_raiz := (xpath('local-name(/*)', v_xml))[1]::text;
    END IF;

    v_linea_tag := CASE v_raiz
                     WHEN 'Invoice'    THEN 'InvoiceLine'
                     WHEN 'CreditNote' THEN 'CreditNoteLine'
                     WHEN 'DebitNote'  THEN 'DebitNoteLine'
                     ELSE NULL END;

    IF v_linea_tag IS NULL THEN
        RETURN ingesta_marcar_error(p_documento_id,
                 format('raíz UBL no soportada: %s', v_raiz));
    END IF;

    v_num       := (xpath('/*/*[local-name()="ID"][1]/text()', v_xml))[1]::text;
    v_fecha     := (xpath('/*/*[local-name()="IssueDate"][1]/text()', v_xml))[1]::text::date;
    v_proveedor := (xpath('//*[local-name()="AccountingSupplierParty"]//*[local-name()="RegistrationName"][1]/text()', v_xml))[1]::text;
    v_payable   := (xpath('//*[local-name()="LegalMonetaryTotal"]/*[local-name()="PayableAmount"]/text()', v_xml))[1]::text::numeric;
    v_impuesto  := (xpath('(//*[local-name()="TaxTotal"]/*[local-name()="TaxAmount"])[1]/text()', v_xml))[1]::text::numeric;

    -- Líneas -> movimientos. El tipo definitivo (venta/compra) lo pone
    -- cartera_facturar_dian abajo; acá entra 'compra' como valor provisional.
    WITH lineas AS (
        SELECT * FROM XMLTABLE(
            XMLNAMESPACES(
                'urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2' AS cac,
                'urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2'     AS cbc),
            ('/*/cac:' || v_linea_tag) PASSING v_xml
            COLUMNS
                descripcion text    PATH 'cac:Item/cbc:Description',
                codigo      text    PATH 'cac:Item/cac:StandardItemIdentification/cbc:ID',
                cantidad    numeric PATH '(cbc:InvoicedQuantity|cbc:CreditedQuantity|cbc:DebitedQuantity)',
                unidad      text    PATH '(cbc:InvoicedQuantity|cbc:CreditedQuantity|cbc:DebitedQuantity)/@unitCode',
                total_linea numeric PATH 'cbc:LineExtensionAmount',
                precio      numeric PATH 'cac:Price/cbc:PriceAmount'
        )
    ),
    ins AS (
        INSERT INTO movimientos (negocio_id, documento_id, tipo, fecha,
                                 cantidad, valor_unitario, valor_total, raw)
        SELECT v_negocio_id, p_documento_id, 'compra', v_fecha,
               l.cantidad,
               coalesce(l.precio, CASE WHEN l.cantidad > 0 THEN l.total_linea / l.cantidad END),
               l.total_linea,
               jsonb_build_object('descripcion', l.descripcion, 'codigo', l.codigo,
                                  'unidad', l.unidad, 'proveedor', v_proveedor)
        FROM lineas l
        RETURNING valor_total
    )
    SELECT count(*), coalesce(sum(valor_total), 0) INTO v_n_lineas, v_suma_lineas FROM ins;

    IF v_n_lineas = 0 THEN
        RETURN ingesta_marcar_error(p_documento_id, 'factura sin líneas legibles');
    END IF;

    UPDATE documentos SET estado = 'parseado', error = NULL WHERE id = p_documento_id;

    -- >>> Lo nuevo respecto a la 004: cartera. Si falla no tumba el parseo:
    -- los movimientos ya están y la factura se puede reconstruir después.
    BEGIN
        v_cartera := cartera_facturar_dian(p_documento_id);
    EXCEPTION WHEN OTHERS THEN
        v_cartera := jsonb_build_object('factura', false, 'error', SQLERRM);
    END;

    RETURN jsonb_build_object(
        'documento_id', p_documento_id,
        'estado', 'parseado',
        'tipo_ubl', v_raiz,
        'numero', v_num,
        'proveedor', v_proveedor,
        'lineas', v_n_lineas,
        'suma_lineas', v_suma_lineas,
        'total_control', v_payable,
        'impuesto', v_impuesto,
        'cuadra', abs(coalesce(v_suma_lineas,0) + coalesce(v_impuesto,0) - coalesce(v_payable,0)) < 1,
        'cartera', v_cartera
    );
END;
$_$;



CREATE FUNCTION public.ingesta_procesar_documento(p_documento_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $_$
DECLARE
    v_funcion text;
    v_clase   text;
    v_result  jsonb;
BEGIN
    SELECT f.funcion_parseo, f.clase INTO v_funcion, v_clase
    FROM documentos d
    JOIN formatos_documento f ON f.codigo = d.formato_codigo
    WHERE d.id = p_documento_id AND f.activo;

    IF v_funcion IS NULL THEN
        RETURN ingesta_marcar_error(p_documento_id, 'formato no reconocido');
    END IF;

    -- Los tabulares necesitan que n8n extraiga las filas primero; el despacho
    -- antes se deducía de pg_proc.pronargs, que era adivinar.
    IF v_clase = 'tabular' THEN
        RETURN jsonb_build_object('documento_id', p_documento_id,
                                  'requiere_filas', true, 'funcion', v_funcion);
    END IF;

    BEGIN
        EXECUTE format('SELECT %I($1)', v_funcion) INTO v_result USING p_documento_id;
    EXCEPTION WHEN OTHERS THEN
        RETURN ingesta_marcar_error(p_documento_id, SQLERRM);
    END;

    RETURN v_result;
END;
$_$;



CREATE FUNCTION public.ingesta_registrar_documento(p_sesion_id bigint, p_negocio_id bigint, p_nombre_archivo text, p_mime text, p_contenido bytea) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_hash      bytea := digest(p_contenido, 'sha256');
    v_id        bigint;
    v_formato   text;
    v_ext       text := lower(split_part(p_nombre_archivo, '.', -1));
    v_op        text;
    v_duplicado boolean := false;
BEGIN
    -- Fase 1a: ¿es un documento que Postgres parsea solo? (DIAN XML)
    SELECT codigo INTO v_formato
    FROM formatos_documento
    WHERE activo AND clase = 'documento'
      AND ( lower(coalesce(p_mime,'')) = ANY(mime_patrones)
            OR v_ext = ANY(extensiones) )
    ORDER BY codigo
    LIMIT 1;

    -- Fase 1b: ¿es una tabla? El formato exacto no se sabe todavía: depende de
    -- las cabeceras, que solo n8n puede leer. Se deja formato_codigo NULL.
    IF v_formato IS NULL THEN
        v_op := (parametro(p_negocio_id, 'ingesta_extractores')) ->> v_ext;
    END IF;

    INSERT INTO documentos (sesion_id, negocio_id, formato_codigo, nombre_archivo,
                            mime, hash, contenido, tamano, estado)
    VALUES (p_sesion_id, p_negocio_id, v_formato, p_nombre_archivo,
            p_mime, v_hash, p_contenido, octet_length(p_contenido), 'pendiente')
    ON CONFLICT (negocio_id, hash) DO UPDATE SET sesion_id = EXCLUDED.sesion_id
    RETURNING id INTO v_id;

    SELECT (xmax <> 0) INTO v_duplicado FROM documentos WHERE id = v_id;

    IF v_formato IS NULL AND v_op IS NULL THEN
        RETURN ingesta_marcar_error(v_id,
                 format('no sé leer archivos %s', coalesce(nullif(v_ext,''), 'sin extensión')))
               || jsonb_build_object('documento_id', v_id, 'reconocido', false,
                                     'requiere_tabla', false);
    END IF;

    RETURN jsonb_build_object(
        'documento_id',   v_id,
        'formato',        v_formato,
        'duplicado',      v_duplicado,
        'reconocido',     true,
        -- n8n mira esto para saber si tiene que extraer la tabla primero.
        'requiere_tabla', v_formato IS NULL,
        'operacion',      v_op,
        'extension',      v_ext
    );
END;
$$;



CREATE FUNCTION public.ingesta_registrar_formato_inferido(p_documento_id bigint, p_columnas text[], p_mapeo jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_canonicas text[] := ARRAY['fecha','producto','categoria','cantidad',
                                'valor_unitario','valor_total','codigo','unidad','impuesto'];
    v_huella  text := ingesta_huella(p_columnas);
    v_cols    jsonb := p_mapeo -> 'columnas';
    v_limpio  jsonb := '{}'::jsonb;
    v_codigo  text;
    v_ext     text;
    v_agregado boolean;
    k text; val text;
BEGIN
    IF p_mapeo ? 'error' THEN
        RETURN ingesta_marcar_error(p_documento_id,
                 format('no reconocí las columnas del archivo (%s)', p_mapeo ->> 'error'));
    END IF;

    IF v_cols IS NULL OR jsonb_typeof(v_cols) <> 'object' THEN
        RETURN ingesta_marcar_error(p_documento_id, 'no pude interpretar las columnas del archivo');
    END IF;

    -- Solo claves canónicas y solo columnas que existan en el archivo.
    FOR k, val IN SELECT * FROM jsonb_each_text(v_cols) LOOP
        IF k = ANY(v_canonicas) AND coalesce(val,'') <> ''
           AND EXISTS (SELECT 1 FROM unnest(p_columnas) c WHERE c = val) THEN
            v_limpio := v_limpio || jsonb_build_object(k, val);
        END IF;
    END LOOP;

    IF NOT (v_limpio ? 'fecha')
       OR NOT (v_limpio ? 'valor_total' OR v_limpio ? 'valor_unitario') THEN
        RETURN ingesta_marcar_error(p_documento_id,
                 'al archivo le falta la columna de fecha o la de valor');
    END IF;

    v_agregado := ingesta_es_agregado(v_limpio);

    SELECT lower(split_part(nombre_archivo, '.', -1)) INTO v_ext
    FROM documentos WHERE id = p_documento_id;

    v_codigo := 'tabular_' || left(v_huella, 10);

    INSERT INTO formatos_documento (codigo, nombre, mime_patrones, extensiones,
                                    funcion_parseo, deteccion, mapeo, clase,
                                    huella, origen)
    VALUES (v_codigo,
            format('Tabla inferida (%s)', coalesce(nullif(v_ext,''),'?')),
            '{}', ARRAY[coalesce(nullif(v_ext,''),'csv')],
            'ingesta_cargar_tabular', '{}'::jsonb,
            jsonb_build_object(
              'tipo',          coalesce(p_mapeo ->> 'tipo', 'venta'),
              'decimal',       coalesce(p_mapeo ->> 'decimal', '.'),
              'miles',         coalesce(p_mapeo ->> 'miles', ''),
              'formato_fecha', p_mapeo ->> 'formato_fecha',
              'agregado',      v_agregado,
              'columnas',      v_limpio),
            'tabular', v_huella, 'inferido')
    ON CONFLICT (codigo) DO UPDATE SET mapeo = EXCLUDED.mapeo
    RETURNING codigo INTO v_codigo;

    UPDATE documentos SET formato_codigo = v_codigo WHERE id = p_documento_id;

    RETURN jsonb_build_object('documento_id', p_documento_id, 'formato', v_codigo,
                              'huella', v_huella, 'columnas_mapeadas', v_limpio,
                              'agregado', v_agregado, 'origen', 'modelo',
                              'nuevo', true);
END;
$$;



CREATE FUNCTION public.ingesta_registrar_formato_resuelto(p_documento_id bigint, p_columnas text[], p_mapeo jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_huella   text := ingesta_huella(p_columnas);
    v_agregado boolean := coalesce((p_mapeo ->> 'agregado')::boolean, false);
    v_codigo   text := 'tabular_' || left(v_huella, 10);
    v_ext      text;
BEGIN
    SELECT lower(split_part(nombre_archivo, '.', -1)) INTO v_ext
    FROM documentos WHERE id = p_documento_id;

    INSERT INTO formatos_documento (codigo, nombre, mime_patrones, extensiones,
                                    funcion_parseo, deteccion, mapeo, clase,
                                    huella, origen)
    VALUES (v_codigo,
            format('Tabla %s (%s)',
                   CASE WHEN v_agregado THEN 'agregada' ELSE 'reconocida' END,
                   coalesce(nullif(v_ext,''),'?')),
            '{}', ARRAY[coalesce(nullif(v_ext,''),'csv')],
            'ingesta_cargar_tabular', '{}'::jsonb,
            jsonb_build_object(
              'tipo',          coalesce(p_mapeo ->> 'tipo', 'venta'),
              'decimal',       coalesce(p_mapeo ->> 'decimal', '.'),
              'miles',         coalesce(p_mapeo ->> 'miles', ''),
              'formato_fecha', p_mapeo ->> 'formato_fecha',
              'agregado',      v_agregado,
              'columnas',      p_mapeo -> 'columnas'),
            'tabular', v_huella, 'inferido')
    ON CONFLICT (codigo) DO UPDATE SET mapeo = EXCLUDED.mapeo
    RETURNING codigo INTO v_codigo;

    UPDATE documentos SET formato_codigo = v_codigo WHERE id = p_documento_id;

    RETURN jsonb_build_object('documento_id', p_documento_id, 'formato', v_codigo,
                              'huella', v_huella, 'agregado', v_agregado,
                              'origen', 'sql', 'nuevo', true);
END;
$$;



CREATE FUNCTION public.ingesta_resolver_columnas(p_columnas text[]) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_res     jsonb := '{}'::jsonb;
    v_usadas  text[] := '{}';
    r         record;
BEGIN
    FOR r IN
        WITH pares AS (
            SELECT s.canonica, c.col, c.ord, min(s.prioridad) AS prioridad
            FROM unnest(p_columnas) WITH ORDINALITY AS c(col, ord)
            JOIN sinonimos_columna s ON norm_texto(c.col) ~ s.patron
            WHERE btrim(coalesce(c.col,'')) <> ''
            GROUP BY s.canonica, c.col, c.ord
        )
        SELECT canonica, col FROM pares
        -- prioridad manda; a igual prioridad gana la columna que aparece antes
        -- en el archivo, que es un desempate estable y no depende del planner.
        ORDER BY prioridad, ord, canonica
    LOOP
        IF NOT (v_res ? r.canonica) AND NOT (r.col = ANY(v_usadas)) THEN
            v_res    := v_res || jsonb_build_object(r.canonica, r.col);
            v_usadas := v_usadas || r.col;
        END IF;
    END LOOP;

    RETURN v_res;
END;
$$;



CREATE FUNCTION public.ingesta_resumen_documento(p_documento_id bigint) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
    SELECT jsonb_build_object(
        'nombre_archivo', d.nombre_archivo,
        'formato',        d.formato_codigo,
        'estado',         d.estado,
        'error',          d.error,
        'filas',          (SELECT count(*) FROM movimientos m WHERE m.documento_id = d.id),
        'desde',          (SELECT min(fecha) FROM movimientos m WHERE m.documento_id = d.id),
        'hasta',          (SELECT max(fecha) FROM movimientos m WHERE m.documento_id = d.id),
        'total',          (SELECT round(coalesce(sum(valor_total),0)) FROM movimientos m WHERE m.documento_id = d.id),
        'productos',      (SELECT count(DISTINCT coalesce(m.raw ->> 'producto', m.raw ->> 'descripcion'))
                             FROM movimientos m WHERE m.documento_id = d.id),
        'sin_resolver',   (SELECT count(*) FROM movimientos m
                            WHERE m.documento_id = d.id AND m.producto_id IS NULL),
        -- >>> nuevo respecto a la 017: si este documento generó factura y el
        -- negocio no tiene NIT, no se pudo saber de qué lado del mostrador está.
        'aviso_nit',      CASE WHEN EXISTS (SELECT 1 FROM facturas f WHERE f.documento_id = d.id)
                                AND (SELECT nullif(btrim(coalesce(n.nit, '')), '')
                                       FROM negocios n WHERE n.id = d.negocio_id) IS NULL
                          THEN ' 💡 La tomé como compra porque no tengo el NIT de tu negocio. Cargalo en tu /portal (Mi negocio) y sabré cuáles facturas son tuyas (te deben) y cuáles recibís (debés).'
                          ELSE '' END
    )
    FROM documentos d WHERE d.id = p_documento_id;
$$;



CREATE FUNCTION public.ingesta_resumen_sesion(p_sesion_id bigint) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $_$
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
$_$;



CREATE FUNCTION public.intencion_agregados(p_negocio_id bigint, p_metrica text, p_desde date, p_hasta date, p_producto bigint DEFAULT NULL::bigint, p_proveedor text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $_$
DECLARE
    v_tipo tipo_movimiento;
    v_out  jsonb;
BEGIN
    IF p_metrica IN ('ventas','compras') THEN
        v_tipo := CASE p_metrica WHEN 'ventas' THEN 'venta' ELSE 'compra' END::tipo_movimiento;

        SELECT jsonb_build_object(
                 'total', round(coalesce(sum(valor_total), 0)),
                 -- La misma cifra ya escrita como se escribe en Colombia. Sin
                 -- esto el modelo entrega "68400" y queda a que se le ocurra
                 -- formatearlo — y si lo formatea por su cuenta, es una cifra
                 -- que no está en el contexto y `validar_cifras` la rechaza.
                 'total_txt', '$' || miles(round(coalesce(sum(valor_total), 0))),
                 'movimientos', count(*),
                 'unidades', round(coalesce(sum(cantidad), 0), 2),
                 'por_mes', coalesce((
                    SELECT jsonb_agg(jsonb_build_object(
                             'mes', to_char(mes, 'YYYY-MM'), 'total', round(t))
                             ORDER BY mes)
                    FROM (SELECT date_trunc('month', m.fecha) AS mes, sum(m.valor_total) AS t
                          FROM mov_visibles m
                          WHERE m.negocio_id = p_negocio_id AND m.tipo = v_tipo
                            AND (p_desde IS NULL OR m.fecha >= p_desde)
                            AND (p_hasta IS NULL OR m.fecha <= p_hasta)
                            AND (p_producto IS NULL OR m.producto_id = p_producto)
                            AND (p_proveedor IS NULL
                                 OR btrim(coalesce(m.raw ->> 'proveedor','')) = p_proveedor)
                          GROUP BY 1) s), '[]'::jsonb),
                 'top_productos', coalesce((
                    SELECT jsonb_agg(jsonb_build_object(
                             'producto', nom, 'total', round(t),
                             'total_txt', '$' || miles(round(t)),
                             'unidades', round(u, 2))
                             ORDER BY t DESC)
                    FROM (SELECT p.nombre_canonico AS nom, sum(m.valor_total) AS t,
                                 sum(m.cantidad) AS u
                          FROM mov_visibles m JOIN productos p ON p.id = m.producto_id
                          WHERE m.negocio_id = p_negocio_id AND m.tipo = v_tipo
                            AND (p_desde IS NULL OR m.fecha >= p_desde)
                            AND (p_hasta IS NULL OR m.fecha <= p_hasta)
                            AND (p_producto IS NULL OR m.producto_id = p_producto)
                            AND (p_proveedor IS NULL
                                 OR btrim(coalesce(m.raw ->> 'proveedor','')) = p_proveedor)
                          GROUP BY 1 ORDER BY 2 DESC LIMIT 8) s), '[]'::jsonb))
          INTO v_out
        FROM mov_visibles m
        WHERE m.negocio_id = p_negocio_id AND m.tipo = v_tipo
          AND (p_desde IS NULL OR m.fecha >= p_desde)
          AND (p_hasta IS NULL OR m.fecha <= p_hasta)
          AND (p_producto IS NULL OR m.producto_id = p_producto)
          AND (p_proveedor IS NULL
               OR btrim(coalesce(m.raw ->> 'proveedor','')) = p_proveedor);

    ELSIF p_metrica = 'gasto_proveedor' THEN
        SELECT jsonb_build_object(
                 'total', round(coalesce(sum(gasto), 0)),
                 'total_txt', '$' || miles(round(coalesce(sum(gasto), 0))),
                 'proveedores', coalesce(jsonb_agg(jsonb_build_object(
                    'proveedor', prov, 'gasto', round(gasto),
                    'gasto_txt', '$' || miles(round(gasto)),
                    'pct', round(gasto * 100.0 / nullif(sum(gasto) OVER (), 0), 1))
                    ORDER BY gasto DESC), '[]'::jsonb))
          INTO v_out
        FROM (SELECT nullif(btrim(coalesce(raw ->> 'proveedor','')),'') AS prov,
                     sum(valor_total) AS gasto
              FROM mov_visibles
              WHERE negocio_id = p_negocio_id AND tipo = 'compra'
                AND (p_desde IS NULL OR fecha >= p_desde)
                AND (p_hasta IS NULL OR fecha <= p_hasta)
                AND nullif(btrim(coalesce(raw ->> 'proveedor','')),'') IS NOT NULL
              GROUP BY 1) g;

    ELSIF p_metrica = 'margen' THEN
        -- Sin ventana: el margen es del estado actual, no de un periodo. Se
        -- ordena de peor a mejor porque la pregunta casi siempre es "¿cuál me
        -- deja poco?", no "¿cuál me deja bien?".
        SELECT jsonb_build_object(
                 'margen_mediano_pct', round(percentile_cont(0.5)
                     WITHIN GROUP (ORDER BY margen_pct)::numeric, 2),
                 'productos', coalesce(jsonb_agg(jsonb_build_object(
                    'producto', nombre_canonico, 'costo', costo_actual,
                    'precio', precio_actual, 'margen_pct', margen_pct)
                    ORDER BY margen_pct), '[]'::jsonb))
          INTO v_out
        FROM v_margen_producto
        WHERE negocio_id = p_negocio_id AND margen_pct IS NOT NULL
          AND (p_producto IS NULL OR producto_id = p_producto);

    ELSIF p_metrica = 'costo' THEN
        SELECT jsonb_build_object(
                 'productos', coalesce(jsonb_agg(jsonb_build_object(
                    'producto', p.nombre_canonico, 'costo_ini', d.costo_ini,
                    'costo_fin', d.costo_fin, 'deriva_pct', d.deriva_pct)
                    ORDER BY d.deriva_pct DESC), '[]'::jsonb))
          INTO v_out
        FROM v_deriva_costo d JOIN productos p ON p.id = d.producto_id
        WHERE d.negocio_id = p_negocio_id
          AND (p_producto IS NULL OR d.producto_id = p_producto);

    ELSIF p_metrica = 'cobertura' THEN
        SELECT jsonb_build_object(
                 'productos', coalesce(jsonb_agg(jsonb_build_object(
                    'producto', p.nombre_canonico,
                    'dias_cobertura', r.dias_cobertura,
                    'unidades_por_dia', r.unidades_por_dia,
                    'stock', b.balance,
                    -- 054: el origen del stock viaja siempre. Responder "te
                    -- quedan 40" sobre una estimación sin decirlo sería
                    -- exactamente lo que A2 vino a arreglar.
                    'origen_stock', r.origen_stock)
                    ORDER BY r.dias_cobertura), '[]'::jsonb))
          INTO v_out
        FROM v_rotacion_producto r
        JOIN productos p ON p.id = r.producto_id
        LEFT JOIN v_balance_unidades b
               ON b.producto_id = r.producto_id AND b.negocio_id = r.negocio_id
        WHERE r.negocio_id = p_negocio_id
          AND (p_producto IS NULL OR r.producto_id = p_producto);

    ELSIF p_metrica = 'utilidad' THEN
        SELECT jsonb_build_object(
                 'productos', coalesce(jsonb_agg(jsonb_build_object(
                    'producto', p.nombre_canonico, 'utilidad', round(pa.utilidad),
                    'utilidad_txt', '$' || miles(round(pa.utilidad)),
                    'pct_utilidad', pa.pct_utilidad,
                    'pct_acumulado', pa.pct_acumulado)
                    ORDER BY pa.utilidad DESC), '[]'::jsonb))
          INTO v_out
        FROM v_pareto_utilidad pa JOIN productos p ON p.id = pa.producto_id
        WHERE pa.negocio_id = p_negocio_id
          AND (p_producto IS NULL OR pa.producto_id = p_producto);
    END IF;

    RETURN coalesce(v_out, '{}'::jsonb);
END;
$_$;



CREATE FUNCTION public.intencion_detectar(p_texto text) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    WITH q AS (SELECT norm_texto(coalesce(p_texto, '')) AS t)
    SELECT i.codigo
    FROM intenciones i, q,
         LATERAL (SELECT count(*) AS n FROM unnest(i.patrones) pa
                   WHERE q.t LIKE '%' || norm_texto(pa) || '%') m
    WHERE i.activo AND m.n > 0
    ORDER BY m.n DESC, i.orden
    LIMIT 1;
$$;



CREATE FUNCTION public.intencion_resolver(p_negocio_id bigint, p_texto text) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $_$
DECLARE
    v_cod    text := intencion_detectar(p_texto);
    v_i      record;
    v_hasta  date;
    v_per    jsonb;
    v_prod   bigint;
    v_prodn  text;
    v_prov   text;
    v_comp   jsonb;
    v_d      date;
    v_h      date;
BEGIN
    IF v_cod IS NULL THEN RETURN NULL; END IF;

    SELECT * INTO v_i FROM intenciones WHERE codigo = v_cod;

    SELECT max(fecha) INTO v_hasta
    FROM mov_visibles WHERE negocio_id = p_negocio_id AND fecha IS NOT NULL;
    IF v_hasta IS NULL THEN RETURN NULL; END IF;   -- sin datos no hay agregado

    v_per := periodo_resolver(p_texto, v_i.periodo, v_hasta);
    v_d := nullif(v_per ->> 'desde', '')::date;
    v_h := nullif(v_per ->> 'hasta', '')::date;

    -- ---- Filtros: solo los que la intención declara aceptar -----------------
    -- El nombre del producto se busca por parecido, con el mismo trigram del
    -- matching (005). Un umbral alto a propósito: preferimos no filtrar a
    -- filtrar por el producto equivocado y dar una cifra que no es.
    IF 'producto' = ANY (v_i.filtros) THEN
        -- `word_similarity` y no `similarity`: la pregunta es larga y el
        -- nombre del producto es corto, así que comparar las dos cadenas
        -- enteras castiga al producto por el largo de la pregunta. Con
        -- "¿cuánto stock me queda de yogurt?", similarity da 0,167 —por debajo
        -- de cualquier umbral razonable— y word_similarity da 0,412.
        SELECT id, nombre_canonico INTO v_prod, v_prodn
        FROM productos
        WHERE negocio_id = p_negocio_id
          AND word_similarity(norm_texto(nombre_canonico), norm_texto(p_texto)) > 0.35
        ORDER BY word_similarity(norm_texto(nombre_canonico), norm_texto(p_texto)) DESC
        LIMIT 1;
    END IF;

    IF 'proveedor' = ANY (v_i.filtros) THEN
        SELECT prov INTO v_prov FROM (
            SELECT DISTINCT nullif(btrim(coalesce(raw ->> 'proveedor','')),'') AS prov
            FROM mov_visibles WHERE negocio_id = p_negocio_id AND tipo = 'compra') s
        WHERE prov IS NOT NULL
          AND word_similarity(norm_texto(prov), norm_texto(p_texto)) > 0.35
        ORDER BY word_similarity(norm_texto(prov), norm_texto(p_texto)) DESC
        LIMIT 1;
    END IF;

    -- ---- Comparativo --------------------------------------------------------
    IF v_i.comparativo IS NOT NULL AND v_d IS NOT NULL THEN
        IF v_i.comparativo = 'mismo_mes_ano_pasado' THEN
            v_comp := jsonb_build_object(
              'contra', 'el mismo periodo del año pasado',
              'desde', (v_d - interval '1 year')::date,
              'hasta', (v_h - interval '1 year')::date,
              'agregados', intencion_agregados(p_negocio_id, v_i.metrica,
                             (v_d - interval '1 year')::date,
                             (v_h - interval '1 year')::date, v_prod, v_prov));
        ELSE
            v_comp := jsonb_build_object(
              'contra', 'el periodo anterior',
              'desde', (v_d - (v_h - v_d) - 1)::date, 'hasta', (v_d - 1)::date,
              'agregados', intencion_agregados(p_negocio_id, v_i.metrica,
                             (v_d - (v_h - v_d) - 1)::date, (v_d - 1)::date,
                             v_prod, v_prov));
        END IF;

        -- "No tengo datos de entonces" no es "vendiste $0". Sin esta distinción
        -- el modelo contesta "el año pasado fue $0", que es falso y además
        -- suena a que el negocio se hundió. Si no hay un solo movimiento en la
        -- ventana de comparación, se dice eso y no una cifra.
        IF coalesce((v_comp #>> '{agregados,movimientos}')::int, 0) = 0 THEN
            v_comp := jsonb_build_object(
              'contra', v_comp ->> 'contra',
              'desde', v_comp -> 'desde', 'hasta', v_comp -> 'hasta',
              'sin_datos', true,
              'nota', 'No hay datos cargados de ese periodo, así que no se puede comparar.');
        END IF;
    END IF;

    RETURN jsonb_strip_nulls(jsonb_build_object(
      'intencion', v_i.codigo,
      'nombre', v_i.nombre,
      'metrica', v_i.metrica,
      'periodo', v_per,
      'filtros', jsonb_strip_nulls(jsonb_build_object(
                   'producto', v_prodn, 'proveedor', v_prov)),
      'agregados', intencion_agregados(p_negocio_id, v_i.metrica, v_d, v_h,
                                       v_prod, v_prov),
      'comparativo', v_comp));
END;
$_$;



CREATE FUNCTION public.jwt_firmar(p_payload jsonb, p_secreto text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT cuerpo || '.' || b64url(hmac(cuerpo, p_secreto, 'sha256'))
    FROM (SELECT b64url(convert_to('{"alg":"HS256","typ":"JWT"}', 'utf8')) || '.' ||
                 b64url(convert_to(p_payload::text, 'utf8')) AS cuerpo) s;
$$;



CREATE FUNCTION public.limpiar_marcado(p_texto text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT btrim(regexp_replace(
             regexp_replace(coalesce(p_texto, ''), '\*\*|__', '', 'g'),
             '^\s*#{1,6}\s*', '', 'g'));
$$;



CREATE FUNCTION public.mantenimiento_ciclo() RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_notif jsonb := '[]';
    v_ejecs jsonb := '[]'::jsonb;
    v_per   jsonb;
BEGIN
    -- 1. Ejecuciones colgadas > 15 min -> fallidas, libera sesión, avisa.
    WITH reaped AS (
        UPDATE ejecuciones e SET estado='fallida',
               error='reaper: colgada más de 15 min', fin=now()
        WHERE e.estado IN ('preparando','procesando','validando')
          AND e.inicio < now() - interval '15 minutes'
        RETURNING e.id, e.sesion_id, e.negocio_id
    ),
    libera AS (
        UPDATE sesiones s SET estado='fallida', cerrada_en=now()
        FROM reaped r WHERE s.id=r.sesion_id
        RETURNING s.id, s.usuario_id
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'chat_id', u.telegram_chat_id,
             'respuestas', jsonb_build_array(jsonb_build_object(
                 'plantilla','ejecucion.fallida','vars','{}'::jsonb)))), '[]')
      INTO v_notif
    FROM libera l JOIN usuarios u ON u.id = l.usuario_id
    WHERE u.telegram_chat_id IS NOT NULL;

    -- 2. Sesiones abandonadas > 24 h -> expiradas, recordatorio único.
    WITH exp AS (
        UPDATE sesiones s SET estado='expirada', cerrada_en=now()
        WHERE s.cerrada_en IS NULL
          AND s.estado IN ('intake','recibiendo')
          AND s.ultima_actividad < now() - interval '24 hours'
        RETURNING s.id, s.usuario_id
    )
    SELECT v_notif || coalesce(jsonb_agg(jsonb_build_object(
             'chat_id', u.telegram_chat_id,
             'respuestas', jsonb_build_array(jsonb_build_object(
                 'plantilla','sesion.recordatorio','vars','{}'::jsonb)))), '[]')
      INTO v_notif
    FROM exp e JOIN usuarios u ON u.id = e.usuario_id
    WHERE u.telegram_chat_id IS NOT NULL;

    -- 3. >>> 067: proactividad por hallazgo urgente.
    BEGIN
        v_notif := v_notif || coalesce(alertas_evaluar() -> 'notificaciones',
                                       '[]'::jsonb);
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO fallas (workflow, tipo, transitoria, detalle)
        VALUES ('alertas_evaluar', 'permanente', false,
                jsonb_build_object('mensaje', SQLERRM, 'sqlstate', SQLSTATE));
    END;

    -- 4. >>> 068: el informe periódico. Mismo guardarraíl: el reaper es lo que
    -- no puede dejar de correr, y ya corrió.
    BEGIN
        v_per   := informes_periodicos_disparar();
        v_notif := v_notif || coalesce(v_per -> 'notificaciones', '[]'::jsonb);
        v_ejecs := coalesce(v_per -> 'ejecuciones', '[]'::jsonb);
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO fallas (workflow, tipo, transitoria, detalle)
        VALUES ('informes_periodicos_disparar', 'permanente', false,
                jsonb_build_object('mensaje', SQLERRM, 'sqlstate', SQLSTATE));
    END;

    RETURN jsonb_build_object('corrido_en', now(),
                              'notificaciones', v_notif,
                              'ejecuciones', v_ejecs);
END;
$$;



CREATE FUNCTION public.match_confirmar_alias(p_alias_id bigint, p_producto_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_negocio_id bigint;
    v_norm       text;
BEGIN
    UPDATE alias SET producto_id = p_producto_id, origen = 'manual', confianza = 1.0
    WHERE id = p_alias_id
    RETURNING negocio_id, texto_norm INTO v_negocio_id, v_norm;

    -- Los movimientos ya cargados que apuntaban a este alias (o cuyo texto
    -- normalizado coincide) heredan el producto confirmado.
    UPDATE movimientos m
    SET producto_id = p_producto_id, alias_id = p_alias_id
    WHERE m.negocio_id = v_negocio_id
      AND m.producto_id IS NULL
      AND (m.alias_id = p_alias_id
           OR norm_texto(m.raw ->> 'descripcion') = v_norm
           OR norm_texto(m.raw ->> 'producto') = v_norm);
END;
$$;



CREATE FUNCTION public.match_resolver_documento(p_documento_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_negocio_id bigint;
    m            record;
    v_texto      text;
    v_codigo     text;
    v_prod_id    bigint;
    v_res        jsonb;
    v_total      int := 0;
    v_resueltos  int := 0;
    v_pendientes int := 0;
    v_nuevos     int := 0;
BEGIN
    SELECT negocio_id INTO v_negocio_id FROM documentos WHERE id = p_documento_id;

    FOR m IN
        SELECT id, tipo, raw FROM movimientos
        WHERE documento_id = p_documento_id AND producto_id IS NULL
    LOOP
        v_total := v_total + 1;
        v_texto  := coalesce(m.raw ->> 'descripcion', m.raw ->> 'producto');
        v_codigo := nullif(m.raw ->> 'codigo', '');
        v_prod_id := NULL;

        -- (a) Compra con código de barras: siembra/reusa producto por código.
        IF v_codigo IS NOT NULL THEN
            SELECT id INTO v_prod_id FROM productos
            WHERE negocio_id = v_negocio_id AND codigo_barras = v_codigo;

            IF v_prod_id IS NULL THEN
                INSERT INTO productos (negocio_id, nombre_canonico, codigo_barras,
                                       unidad, categoria)
                VALUES (v_negocio_id, coalesce(v_texto, v_codigo), v_codigo,
                        m.raw ->> 'unidad', NULL)
                RETURNING id INTO v_prod_id;
                v_nuevos := v_nuevos + 1;
            END IF;

            -- memoriza el texto como alias exacto para el POS futuro
            IF v_texto IS NOT NULL THEN
                INSERT INTO alias (negocio_id, texto_norm, producto_id, confianza, origen)
                VALUES (v_negocio_id, norm_texto(v_texto), v_prod_id, 1.0, 'exacto')
                ON CONFLICT (negocio_id, texto_norm)
                  DO UPDATE SET producto_id = EXCLUDED.producto_id, origen = 'exacto';
            END IF;

            UPDATE movimientos SET producto_id = v_prod_id WHERE id = m.id;
            v_resueltos := v_resueltos + 1;
            CONTINUE;
        END IF;

        -- (b) Sin código: resolver por texto (alias exacto / trigram / pendiente).
        v_res := match_resolver_producto(v_negocio_id, v_texto);
        IF (v_res ->> 'resuelto')::boolean THEN
            UPDATE movimientos
            SET producto_id = (v_res ->> 'producto_id')::bigint,
                alias_id    = (v_res ->> 'alias_id')::bigint
            WHERE id = m.id;
            v_resueltos := v_resueltos + 1;
        ELSE
            UPDATE movimientos SET alias_id = (v_res ->> 'alias_id')::bigint
            WHERE id = m.id;
            v_pendientes := v_pendientes + 1;
        END IF;
    END LOOP;

    RETURN jsonb_build_object('documento_id', p_documento_id, 'total', v_total,
                              'resueltos', v_resueltos, 'pendientes', v_pendientes,
                              'productos_nuevos', v_nuevos);
END;
$$;



CREATE FUNCTION public.match_resolver_producto(p_negocio_id bigint, p_texto text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_norm     text := norm_texto(p_texto);
    v_umbral   real := coalesce((parametro(p_negocio_id, 'match_umbral_trgm'))::text::real, 0.45);
    v_alias_id bigint;
    v_prod_id  bigint;
    v_sim      real;
    v_nombre   text;
BEGIN
    IF v_norm = '' THEN
        RETURN jsonb_build_object('resuelto', false, 'motivo', 'texto vacío');
    END IF;

    -- 1. Alias exacto ya conocido y ya resuelto.
    SELECT a.id, a.producto_id INTO v_alias_id, v_prod_id
    FROM alias a
    WHERE a.negocio_id = p_negocio_id AND a.texto_norm = v_norm
    LIMIT 1;

    IF FOUND AND v_prod_id IS NOT NULL THEN
        SELECT nombre_canonico INTO v_nombre FROM productos WHERE id = v_prod_id;
        RETURN jsonb_build_object('resuelto', true, 'producto_id', v_prod_id,
                                  'producto', v_nombre, 'alias_id', v_alias_id,
                                  'origen', 'exacto');
    END IF;

    -- 2. Trigram contra productos existentes del negocio.
    SELECT p.id, p.nombre_canonico, similarity(norm_texto(p.nombre_canonico), v_norm)
      INTO v_prod_id, v_nombre, v_sim
    FROM productos p
    WHERE p.negocio_id = p_negocio_id
    ORDER BY similarity(norm_texto(p.nombre_canonico), v_norm) DESC
    LIMIT 1;

    IF v_prod_id IS NOT NULL AND v_sim >= v_umbral THEN
        -- Auto-confirma y memoriza el alias para la próxima.
        IF v_alias_id IS NULL THEN
            INSERT INTO alias (negocio_id, texto_norm, producto_id, confianza, origen)
            VALUES (p_negocio_id, v_norm, v_prod_id, v_sim, 'trigram')
            ON CONFLICT (negocio_id, texto_norm)
              DO UPDATE SET producto_id = EXCLUDED.producto_id,
                            confianza = EXCLUDED.confianza, origen = 'trigram'
            RETURNING id INTO v_alias_id;
        ELSE
            UPDATE alias SET producto_id = v_prod_id, confianza = v_sim, origen = 'trigram'
            WHERE id = v_alias_id;
        END IF;

        RETURN jsonb_build_object('resuelto', true, 'producto_id', v_prod_id,
                                  'producto', v_nombre, 'alias_id', v_alias_id,
                                  'origen', 'trigram', 'similitud', round(v_sim::numeric, 3));
    END IF;

    -- 3. Nada bueno: deja el texto como alias pendiente. No inventa producto.
    IF v_alias_id IS NULL THEN
        INSERT INTO alias (negocio_id, texto_norm, origen)
        VALUES (p_negocio_id, v_norm, 'pendiente')
        ON CONFLICT (negocio_id, texto_norm) DO NOTHING
        RETURNING id INTO v_alias_id;
        IF v_alias_id IS NULL THEN
            SELECT id INTO v_alias_id FROM alias
            WHERE negocio_id = p_negocio_id AND texto_norm = v_norm;
        END IF;
    END IF;

    RETURN jsonb_build_object('resuelto', false, 'alias_id', v_alias_id,
                              'texto', v_norm, 'origen', 'pendiente',
                              'mejor_candidato', v_nombre,
                              'similitud', round(coalesce(v_sim,0)::numeric, 3));
END;
$$;



CREATE FUNCTION public.mercado_compras_bienvenida(p_negocio_id bigint, p_chat_id bigint) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $_$
DECLARE
    v record;
BEGIN
    SELECT count(DISTINCT m.documento_id)                              AS documentos,
           count(DISTINCT coalesce(p.nombre_canonico,
                 m.raw ->> 'descripcion', m.raw ->> 'producto'))       AS productos,
           round(coalesce(sum(m.valor_total), 0))                      AS gasto,
           min(m.fecha) AS desde, max(m.fecha) AS hasta
    INTO v
    FROM mov_visibles m
    LEFT JOIN productos p ON p.id = m.producto_id
    WHERE m.negocio_id = p_negocio_id AND m.tipo = 'compra';

    IF coalesce(v.documentos, 0) = 0 THEN
        RETURN router_respuesta(p_chat_id, 'mercado.pedir_facturas');
    END IF;

    RETURN router_respuesta(p_chat_id, 'mercado.datos_previos', jsonb_build_object(
        'documentos', v.documentos,
        'productos',  v.productos,
        'gasto',      '$' || miles(v.gasto),
        'rango',      coalesce(' ' || nullif(periodo_es(v.desde, v.hasta), ''), '')));
END;
$_$;



CREATE FUNCTION public.mes_es(p_fecha date) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT (ARRAY['enero','febrero','marzo','abril','mayo','junio','julio',
                  'agosto','septiembre','octubre','noviembre','diciembre']
           )[extract(month from p_fecha)::int];
$$;



CREATE FUNCTION public.miles(p numeric) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT replace(to_char(round(coalesce(p, 0)), 'FM999,999,999,999'), ',', '.');
$$;



CREATE FUNCTION public.movimientos_limite_plan() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE v_desde date;
BEGIN
    IF NEW.fecha IS NULL THEN RETURN NEW; END IF;

    v_desde := plan_desde(NEW.negocio_id);
    IF v_desde IS NULL OR NEW.fecha >= v_desde THEN RETURN NEW; END IF;

    IF NEW.documento_id IS NOT NULL THEN
        UPDATE documentos SET filas_fuera_de_plan = filas_fuera_de_plan + 1
        WHERE id = NEW.documento_id;
    END IF;
    RETURN NEW;   -- fuera de la ventana de LECTURA, pero se guarda igual
END;
$$;



CREATE FUNCTION public.nit_dv(p_nit text) RETURNS integer
    LANGUAGE plpgsql IMMUTABLE
    AS $_$
DECLARE
    v_pesos int[] := ARRAY[3,7,13,17,19,23,29,37,41,43,47,53,59,67,71];
    v_suma  int := 0;
    v_res   int;
    i       int;
BEGIN
    IF p_nit !~ '^\d{1,15}$' THEN
        RETURN NULL;
    END IF;
    FOR i IN 1..length(p_nit) LOOP
        -- dígito i-ésimo desde la derecha por el peso i-ésimo
        v_suma := v_suma + substr(p_nit, length(p_nit) - i + 1, 1)::int * v_pesos[i];
    END LOOP;
    v_res := v_suma % 11;
    RETURN CASE WHEN v_res IN (0, 1) THEN v_res ELSE 11 - v_res END;
END;
$_$;



CREATE FUNCTION public.norm_pregunta(p text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT btrim(regexp_replace(
             regexp_replace(norm_texto(p), '[^a-z0-9ñ ]', '', 'g'), '\s+', ' ', 'g'));
$$;



CREATE FUNCTION public.norm_texto(p text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT btrim(regexp_replace(lower(unaccent(coalesce(p, ''))), '\s+', ' ', 'g'));
$$;



CREATE FUNCTION public.pago_registrar(p_factura_id bigint, p_valor numeric, p_fecha date DEFAULT NULL::date, p_medio text DEFAULT NULL::text, p_origen text DEFAULT 'portal'::text, p_usuario_id bigint DEFAULT NULL::bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE v_saldo numeric;
BEGIN
    IF coalesce(p_valor, 0) <= 0 THEN
        RAISE EXCEPTION 'el pago debe ser mayor que cero' USING ERRCODE = '22023';
    END IF;

    SELECT saldo INTO v_saldo FROM facturas WHERE id = p_factura_id FOR UPDATE;
    IF v_saldo IS NULL THEN
        RAISE EXCEPTION 'no existe esa factura' USING ERRCODE = '42501';
    END IF;
    IF p_valor > v_saldo THEN
        RAISE EXCEPTION 'el pago (%) supera el saldo (%)', p_valor, v_saldo
              USING ERRCODE = '22023';
    END IF;

    INSERT INTO pagos (factura_id, fecha, valor, medio, origen, usuario_id)
    VALUES (p_factura_id, coalesce(p_fecha, current_date), p_valor,
            p_medio, p_origen, p_usuario_id);

    UPDATE facturas SET saldo = saldo - p_valor WHERE id = p_factura_id
    RETURNING saldo INTO v_saldo;

    RETURN jsonb_build_object('ok', true, 'saldo', v_saldo);
END;
$$;



CREATE FUNCTION public.parametro(p_negocio_id bigint, p_clave text) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
    SELECT valor FROM parametros
    WHERE clave = p_clave
      AND (negocio_id = p_negocio_id OR negocio_id IS NULL)
    ORDER BY negocio_id NULLS LAST
    LIMIT 1;
$$;



CREATE FUNCTION public.pedido_sugerido(p_negocio_id bigint) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $_$
DECLARE
    v_items jsonb;
    v_total numeric;
    v_sin   int;
BEGIN
    SELECT coalesce(jsonb_agg(x ORDER BY (x ->> 'costo')::numeric DESC NULLS LAST),
                    '[]'::jsonb),
           coalesce(sum((x ->> 'costo')::numeric), 0),
           count(*) FILTER (WHERE x ->> 'proveedor' IS NULL)
      INTO v_items, v_total, v_sin
    FROM (
        SELECT jsonb_strip_nulls(jsonb_build_object(
                 'recomendacion_id', r.id,
                 'producto', r.titulo,
                 'unidades', u.n,
                 'unidades_txt', unidades_es(u.n),
                 'proveedor', pb.proveedor,
                 'precio_unitario', pb.precio,
                 'costo', CASE WHEN pb.precio IS NOT NULL
                               THEN round(u.n * pb.precio) END,
                 'costo_txt', CASE WHEN pb.precio IS NOT NULL
                                   THEN '$' || miles(round(u.n * pb.precio)) END,
                 -- 054: si el stock con el que se decidió pedir era estimado,
                 -- la lista lo dice. Comprar de más por una cuenta inventada es
                 -- exactamente el error que A2 vino a evitar.
                 'stock_estimado', (r.origen_stock = 'estimado'),
                 'prioridad', r.prioridad)) AS x
        FROM recomendaciones r
        CROSS JOIN LATERAL (
            SELECT nullif(r.datos ->> 'unidades_pedir', '')::numeric AS n) u
        LEFT JOIN v_proveedor_mas_barato pb
               ON pb.negocio_id = r.negocio_id
              AND pb.producto_id = nullif(split_part(r.clave_objeto, ':', 2), '')::bigint
        WHERE r.negocio_id = p_negocio_id
          AND r.regla = 'agota'
          AND r.estado IN ('nueva','vigente')
          AND u.n IS NOT NULL AND u.n > 0
    ) s;

    RETURN jsonb_build_object(
      'items', v_items,
      'productos', jsonb_array_length(v_items),
      'total', round(v_total),
      'total_txt', '$' || miles(round(v_total)),
      -- Se declara, no se disimula: un total al que le faltan productos sin
      -- precio conocido no es el total de la compra.
      'sin_precio', v_sin,
      'generado_en', now());
END;
$_$;



CREATE FUNCTION public.perfil_negocio(p_negocio_id bigint) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
    SELECT jsonb_build_object(
      'negocio_id', negocio_id,
      'nombre', nombre,
      'plan', plan,
      'tipo', tipo_nombre,
      'tiene_nit', tiene_nit,
      'periodo', periodo,
      'productos', productos,
      'top_productos', top_productos,
      'proveedores', proveedores,
      'estacionalidad', estacionalidad,
      'problemas_recurrentes', problemas_recurrentes,
      'acciones', acciones,
      -- >>> 066: de lo que se cerró, ¿cuánto sirvió?
      'resultados', (SELECT jsonb_build_object(
                       'positivo', count(*) FILTER (WHERE resultado = 'positivo'),
                       'neutro',   count(*) FILTER (WHERE resultado = 'neutro'),
                       'negativo', count(*) FILTER (WHERE resultado = 'negativo'),
                       'sin_medir', count(*) FILTER (
                          WHERE resultado IS NULL
                            AND estado NOT IN ('nueva','vigente')))
                     FROM recomendaciones WHERE negocio_id = p_negocio_id),
      'salud_historia', salud_historia,
      'calidad', calidad)
    FROM v_perfil_negocio WHERE negocio_id = p_negocio_id;
$$;



CREATE FUNCTION public.periodo_es(p_desde date, p_hasta date) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT CASE
      WHEN p_desde IS NULL OR p_hasta IS NULL THEN ''
      WHEN p_desde = p_hasta THEN
        format('%s de %s de %s', extract(day from p_desde)::int,
               mes_es(p_desde), extract(year from p_desde)::int)
      WHEN date_trunc('month', p_desde) = date_trunc('month', p_hasta) THEN
        format('del %s al %s de %s de %s', extract(day from p_desde)::int,
               extract(day from p_hasta)::int, mes_es(p_hasta),
               extract(year from p_hasta)::int)
      WHEN extract(year from p_desde) = extract(year from p_hasta) THEN
        format('del %s de %s al %s de %s de %s',
               extract(day from p_desde)::int, mes_es(p_desde),
               extract(day from p_hasta)::int, mes_es(p_hasta),
               extract(year from p_hasta)::int)
      ELSE
        format('del %s de %s de %s al %s de %s de %s',
               extract(day from p_desde)::int, mes_es(p_desde), extract(year from p_desde)::int,
               extract(day from p_hasta)::int, mes_es(p_hasta), extract(year from p_hasta)::int)
    END;
$$;



CREATE FUNCTION public.periodo_resolver(p_texto text, p_defecto text, p_hasta date) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_t     text := norm_texto(coalesce(p_texto, ''));
    v_mes   int;
    v_ano   int;
    v_desde date;
    v_fin   date;
    v_etq   text;
    v_meses text[] := ARRAY['enero','febrero','marzo','abril','mayo','junio',
                            'julio','agosto','septiembre','octubre','noviembre','diciembre'];
BEGIN
    -- ---- Un mes nombrado: "en marzo", "marzo del año pasado" ---------------
    -- Palabra COMPLETA (`\y`), no subcadena. Con LIKE '%mayo%', la pregunta
    -- "¿cuánto le compré a Mayorista Centro?" se respondía por el mes de mayo:
    -- el bot contestaba con seguridad una cifra que no era la que se le pidió,
    -- sin avisar de nada. Es la clase de error que hace que el dueño deje de
    -- creerle, y no lo atrapa ninguna prueba que no use nombres reales.
    SELECT i INTO v_mes FROM generate_subscripts(v_meses, 1) i
    WHERE v_t ~ ('\y' || v_meses[i] || '\y') LIMIT 1;

    IF v_mes IS NOT NULL THEN
        -- El año: el que se nombre, o el más reciente en que ese mes existe
        -- dentro de los datos. Preguntar por "marzo" en agosto es preguntar por
        -- el marzo de este año, no por el de hace tres.
        SELECT (regexp_matches(v_t, '\y(20\d{2})\y'))[1]::int INTO v_ano;
        IF v_ano IS NULL THEN
            v_ano := CASE WHEN v_mes <= extract(month FROM p_hasta)::int
                          THEN extract(year FROM p_hasta)::int
                          ELSE extract(year FROM p_hasta)::int - 1 END;
        END IF;
        IF v_t LIKE '%ano pasado%' OR v_t LIKE '%año pasado%' THEN
            v_ano := v_ano - 1;
        END IF;
        v_desde := make_date(v_ano, v_mes, 1);
        v_fin   := (v_desde + interval '1 month - 1 day')::date;
        RETURN jsonb_build_object('desde', v_desde, 'hasta', v_fin,
                                  'etiqueta', v_meses[v_mes] || ' de ' || v_ano,
                                  'origen', 'texto');
    END IF;

    -- ---- Expresiones relativas ---------------------------------------------
    v_etq := NULL;
    IF v_t LIKE '%este mes%' THEN
        v_desde := date_trunc('month', p_hasta)::date;
        v_fin   := p_hasta; v_etq := 'este mes';
    ELSIF v_t LIKE '%mes pasado%' OR v_t LIKE '%mes anterior%' THEN
        v_desde := (date_trunc('month', p_hasta) - interval '1 month')::date;
        v_fin   := (date_trunc('month', p_hasta) - interval '1 day')::date;
        v_etq   := 'el mes pasado';
    ELSIF v_t LIKE '%ano pasado%' THEN
        v_desde := make_date(extract(year FROM p_hasta)::int - 1, 1, 1);
        v_fin   := make_date(extract(year FROM p_hasta)::int - 1, 12, 31);
        v_etq   := 'el año pasado';
    ELSIF v_t LIKE '%este ano%' THEN
        v_desde := date_trunc('year', p_hasta)::date;
        v_fin   := p_hasta; v_etq := 'este año';
    ELSIF v_t ~ 'ultim[oa]s? +\d+ +dias' THEN
        v_desde := p_hasta - ((regexp_matches(v_t, 'ultim[oa]s? +(\d+) +dias'))[1]::int);
        v_fin   := p_hasta;
        v_etq   := 'los últimos ' || (p_hasta - v_desde) || ' días';
    END IF;

    IF v_etq IS NOT NULL THEN
        RETURN jsonb_build_object('desde', v_desde, 'hasta', v_fin,
                                  'etiqueta', v_etq, 'origen', 'texto');
    END IF;

    -- ---- El defecto de la intención ----------------------------------------
    RETURN CASE p_defecto
      WHEN 'mes_actual' THEN jsonb_build_object(
        'desde', date_trunc('month', p_hasta)::date, 'hasta', p_hasta,
        'etiqueta', 'este mes', 'origen', 'defecto')
      WHEN 'mes_anterior' THEN jsonb_build_object(
        'desde', (date_trunc('month', p_hasta) - interval '1 month')::date,
        'hasta', (date_trunc('month', p_hasta) - interval '1 day')::date,
        'etiqueta', 'el mes pasado', 'origen', 'defecto')
      WHEN 'ano_actual' THEN jsonb_build_object(
        'desde', date_trunc('year', p_hasta)::date, 'hasta', p_hasta,
        'etiqueta', 'este año', 'origen', 'defecto')
      WHEN 'ultimos_30' THEN jsonb_build_object(
        'desde', p_hasta - 30, 'hasta', p_hasta,
        'etiqueta', 'los últimos 30 días', 'origen', 'defecto')
      ELSE jsonb_build_object(
        'desde', NULL, 'hasta', NULL,
        'etiqueta', 'toda tu historia cargada', 'origen', 'defecto')
    END;
END;
$$;



CREATE FUNCTION public.plan_desde(p_negocio_id bigint) RETURNS date
    LANGUAGE sql STABLE
    AS $$
    SELECT CASE
        WHEN coalesce((SELECT plan FROM negocios WHERE id = p_negocio_id), 'free') <> 'free'
          THEN NULL
        ELSE date_trunc('month', current_date)::date
             - (coalesce((parametro(p_negocio_id, 'plan_free_meses_historia'))::text::int, 3) - 1)
               * interval '1 month'
    END::date;
$$;



CREATE FUNCTION public.plantilla_cuerpo(p_clave text, p_defecto text) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    SELECT coalesce((SELECT cuerpo FROM plantillas
                     WHERE clave = p_clave AND activo LIMIT 1), p_defecto);
$$;



CREATE FUNCTION public.plantilla_cuerpo_srv(p_clave text, p_servicio text, p_defecto text) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    SELECT coalesce(
      (SELECT cuerpo FROM plantillas
        WHERE clave = p_clave || '.' || coalesce(p_servicio, '—') AND activo LIMIT 1),
      (SELECT cuerpo FROM plantillas WHERE clave = p_clave AND activo LIMIT 1),
      p_defecto);
$$;



CREATE FUNCTION public.portal_alias_confirmar(p_alias_id bigint, p_producto_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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



CREATE FUNCTION public.portal_alias_pendientes(p_limite integer DEFAULT 50) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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



CREATE FUNCTION public.portal_cartera() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    RETURN jsonb_build_object(
      -- Las dos cifras grandes: cuánto me deben y cuánto debo, y de eso
      -- cuánto ya está vencido.
      'resumen', (
        SELECT jsonb_build_object(
                 'por_cobrar', coalesce(sum(saldo) FILTER (WHERE tipo = 'venta'),  0),
                 'por_pagar',  coalesce(sum(saldo) FILTER (WHERE tipo = 'compra'), 0),
                 'vencido_cobrar', coalesce(sum(saldo) FILTER
                   (WHERE tipo = 'venta'  AND vencimiento < current_date), 0),
                 'vencido_pagar',  coalesce(sum(saldo) FILTER
                   (WHERE tipo = 'compra' AND vencimiento < current_date), 0))
        FROM facturas WHERE negocio_id = v_negocio AND saldo > 0),

      'edades', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
                 'tipo', e.tipo, 'edad', e.edad,
                 'facturas', e.facturas, 'saldo', e.saldo))
        FROM v_cartera_edades e WHERE e.negocio_id = v_negocio), '[]'::jsonb),

      'terceros', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
                 'tercero_id', t.tercero_id, 'nombre', t.nombre, 'nit', t.nit,
                 'tipo', t.tipo, 'facturas', t.facturas, 'saldo', t.saldo,
                 'dias_mora', t.dias_mora)
               ORDER BY t.saldo DESC)
        FROM v_cartera_tercero t WHERE t.negocio_id = v_negocio), '[]'::jsonb),

      -- Las facturas abiertas, la más urgente primero (sin vencimiento al
      -- final: no se le puede cobrar mora a lo que no tiene fecha).
      'facturas', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
                 'id', f.id, 'tipo', f.tipo, 'numero', f.numero,
                 'tercero', t.nombre, 'emision', f.emision,
                 'vencimiento', f.vencimiento, 'total', f.total,
                 'saldo', f.saldo,
                 'dias_mora', CASE WHEN f.vencimiento < current_date
                                   THEN current_date - f.vencimiento END)
               ORDER BY f.vencimiento ASC NULLS LAST, f.id)
        FROM facturas f LEFT JOIN terceros t ON t.id = f.tercero_id
        WHERE f.negocio_id = v_negocio AND f.saldo > 0), '[]'::jsonb));
END;
$$;



CREATE FUNCTION public.portal_claim(p_clave text) RETURNS bigint
    LANGUAGE sql STABLE
    AS $$
    SELECT nullif(current_setting('request.jwt.claims', true)::jsonb ->> p_clave, '')::bigint;
$$;



CREATE FUNCTION public.portal_conocimiento(p_tipo text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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



CREATE FUNCTION public.portal_conocimiento_borrar(p_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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



CREATE FUNCTION public.portal_conocimiento_guardar(p_titulo text, p_tipo text DEFAULT 'faq'::text, p_contenido text DEFAULT NULL::text, p_clave text DEFAULT NULL::text, p_datos jsonb DEFAULT '{}'::jsonb, p_id bigint DEFAULT NULL::bigint, p_pendiente_id bigint DEFAULT NULL::bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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



CREATE FUNCTION public.portal_conteo_guardar(p_producto_id bigint, p_unidades numeric, p_fecha date DEFAULT NULL::date) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_negocio bigint := portal_negocio();
    v_id      bigint;
BEGIN
    -- El producto tiene que ser de este negocio: el id llega del navegador.
    IF NOT EXISTS (SELECT 1 FROM productos
                   WHERE id = p_producto_id AND negocio_id = v_negocio) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'producto_ajeno');
    END IF;
    IF p_unidades IS NULL OR p_unidades < 0 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'unidades_invalidas');
    END IF;

    INSERT INTO conteos_inventario (negocio_id, producto_id, fecha, unidades, origen)
    VALUES (v_negocio, p_producto_id, coalesce(p_fecha, current_date), p_unidades, 'portal')
    ON CONFLICT (negocio_id, producto_id, fecha)
      DO UPDATE SET unidades = EXCLUDED.unidades, origen = 'portal'
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$$;



CREATE FUNCTION public.portal_conteos(p_limite integer DEFAULT 50) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'id', c.id, 'producto', p.nombre_canonico, 'producto_id', p.id,
             'fecha', c.fecha, 'unidades', c.unidades, 'origen', c.origen)
             ORDER BY c.fecha DESC, c.id DESC), '[]'::jsonb)
    FROM (SELECT * FROM conteos_inventario
          WHERE negocio_id = portal_negocio()
          ORDER BY fecha DESC, id DESC
          LIMIT greatest(coalesce(p_limite, 50), 1)) c
    JOIN productos p ON p.id = c.producto_id;
$$;



CREATE FUNCTION public.portal_cotizacion_guardar(p_items jsonb, p_cliente text DEFAULT NULL::text, p_notas text DEFAULT NULL::text, p_vigente_hasta date DEFAULT NULL::date) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_negocio bigint := portal_negocio();
    v_usuario bigint := portal_claim('usuario_id');
    v_items   jsonb;
    v_total   numeric;
    v_id      bigint;
    v_token   text := encode(gen_random_bytes(12), 'hex');
BEGIN
    -- Normalizar y validar en un solo paso: título obligatorio, cantidad > 0,
    -- valor >= 0. El total de cada línea y el general se calculan acá; lo que
    -- mande el navegador en esos campos se ignora.
    SELECT jsonb_agg(jsonb_build_object(
             'titulo', i.titulo, 'unidad', i.unidad,
             'cantidad', i.cantidad, 'valor_unitario', i.valor,
             'total', round(i.cantidad * i.valor))),
           coalesce(sum(round(i.cantidad * i.valor)), 0)
      INTO v_items, v_total
    FROM (SELECT btrim(coalesce(e ->> 'titulo', ''))            AS titulo,
                 nullif(btrim(coalesce(e ->> 'unidad', '')), '') AS unidad,
                 (e ->> 'cantidad')::numeric                     AS cantidad,
                 (e ->> 'valor_unitario')::numeric               AS valor
          FROM jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) e) i
    WHERE i.titulo <> '' AND i.cantidad > 0 AND i.valor >= 0;

    IF v_items IS NULL OR jsonb_array_length(v_items) = 0 THEN
        RAISE EXCEPTION 'la cotización necesita al menos un producto con cantidad'
              USING ERRCODE = '22023';
    END IF;

    INSERT INTO cotizaciones (negocio_id, creado_por, cliente, notas, items,
                              total, token, vigente_hasta)
    VALUES (v_negocio, v_usuario, nullif(btrim(coalesce(p_cliente, '')), ''),
            nullif(btrim(coalesce(p_notas, '')), ''), v_items, v_total,
            v_token, p_vigente_hasta)
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'id', v_id, 'token', v_token,
                              'total', v_total);
END;
$$;



CREATE FUNCTION public.portal_cotizacion_publica(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_out jsonb;
BEGIN
    SELECT jsonb_build_object(
             'ok', true,
             'negocio', jsonb_build_object('nombre', n.nombre, 'nit', n.nit,
                                           'tipo', n.tipo),
             'cliente', c.cliente, 'notas', c.notas, 'items', c.items,
             'total', c.total, 'creado_en', c.creado_en,
             'vigente_hasta', c.vigente_hasta,
             'vencida', c.vigente_hasta IS NOT NULL AND c.vigente_hasta < current_date)
      INTO v_out
    FROM cotizaciones c JOIN negocios n ON n.id = c.negocio_id
    WHERE c.token = coalesce(p_token, '') AND c.estado = 'abierta';

    RETURN coalesce(v_out, jsonb_build_object('ok', false, 'error', 'no_existe'));
END;
$$;



CREATE FUNCTION public.portal_cotizacion_revocar(p_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_negocio bigint := portal_negocio();
    v_n       int;
BEGIN
    UPDATE cotizaciones SET estado = 'revocada'
    WHERE id = p_id AND negocio_id = v_negocio;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN jsonb_build_object('ok', v_n > 0);
END;
$$;



CREATE FUNCTION public.portal_cotizaciones(p_limite integer DEFAULT 30) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    RETURN coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', c.id, 'cliente', c.cliente, 'total', c.total,
               'estado', c.estado, 'token', c.token,
               'items', jsonb_array_length(c.items),
               'vigente_hasta', c.vigente_hasta, 'creado_en', c.creado_en)
             ORDER BY c.creado_en DESC, c.id DESC)
      FROM (SELECT * FROM cotizaciones WHERE negocio_id = v_negocio
            ORDER BY creado_en DESC, id DESC
            LIMIT greatest(coalesce(p_limite, 30), 1)) c), '[]'::jsonb);
END;
$$;



CREATE FUNCTION public.portal_documentos(p_limite integer DEFAULT 20) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    RETURN coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', d.id, 'nombre', d.nombre_archivo,
               'formato', coalesce(f.nombre, d.formato_codigo, 'desconocido'),
               'estado', d.estado, 'error', d.error, 'fecha', d.creado_en,
               'movimientos', (SELECT count(*) FROM movimientos m
                               WHERE m.documento_id = d.id))
             ORDER BY d.creado_en DESC, d.id DESC)
      FROM (SELECT * FROM documentos
            WHERE negocio_id = v_negocio
            ORDER BY creado_en DESC, id DESC
            LIMIT greatest(coalesce(p_limite, 20), 1)) d
      LEFT JOIN formatos_documento f ON f.codigo = d.formato_codigo), '[]'::jsonb);
END;
$$;



CREATE FUNCTION public.portal_factura_guardar(p_tercero text, p_total numeric, p_vencimiento date, p_numero text DEFAULT NULL::text, p_emision date DEFAULT NULL::date, p_nit text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_negocio bigint := portal_negocio();
    v_nombre  text   := nullif(btrim(coalesce(p_tercero, '')), '');
    v_terc    bigint;
    v_id      bigint;
BEGIN
    IF v_nombre IS NULL OR coalesce(p_total, 0) <= 0 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'faltan_datos');
    END IF;

    -- El tercero se reusa por nombre normalizado: sin esto, "Panadería El Sol"
    -- y "panaderia el sol" serían dos deudores distintos y la cartera de cada
    -- uno se vería la mitad de grande de lo que es.
    SELECT id INTO v_terc FROM terceros
    WHERE negocio_id = v_negocio AND norm_texto(nombre) = norm_texto(v_nombre)
    LIMIT 1;

    IF v_terc IS NULL THEN
        INSERT INTO terceros (negocio_id, nombre, nit)
        VALUES (v_negocio, v_nombre, nullif(btrim(coalesce(p_nit, '')), ''))
        RETURNING id INTO v_terc;
    END IF;

    INSERT INTO facturas (negocio_id, tercero_id, tipo, numero, emision,
                          vencimiento, total, saldo)
    VALUES (v_negocio, v_terc, 'venta', nullif(btrim(coalesce(p_numero,'')), ''),
            coalesce(p_emision, current_date), p_vencimiento,
            round(p_total), round(p_total))
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'factura_id', v_id,
                              'tercero_id', v_terc, 'tercero', v_nombre);
END;
$$;



CREATE FUNCTION public.portal_informe(p_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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



CREATE FUNCTION public.portal_informes(p_limite integer DEFAULT 20) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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



CREATE FUNCTION public.portal_mov_nombre(p_raw jsonb, p_mapeo jsonb) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT coalesce(p_raw ->> 'descripcion',
                    p_raw ->> 'producto',
                    p_raw ->> nullif(p_mapeo #>> '{columnas,producto}', ''));
$$;



CREATE FUNCTION public.portal_movimientos(p_tipo text DEFAULT NULL::text, p_limite integer DEFAULT 50) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    -- Un tipo desconocido no revienta el fetch: se ignora el filtro.
    IF p_tipo IS NOT NULL AND p_tipo NOT IN ('compra', 'venta', 'ajuste') THEN
        p_tipo := NULL;
    END IF;

    RETURN coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', m.id, 'tipo', m.tipo, 'fecha', m.fecha,
               'nombre', coalesce(p.nombre_canonico,
                                  portal_mov_nombre(m.raw, f.mapeo)),
               'tercero', m.raw ->> 'proveedor',
               'cantidad', m.cantidad,
               'valor_unitario', m.valor_unitario,
               'valor_total', m.valor_total)
             ORDER BY m.fecha DESC NULLS LAST, m.id DESC)
      FROM (SELECT * FROM movimientos
            WHERE negocio_id = v_negocio
              AND (p_tipo IS NULL OR tipo = p_tipo::tipo_movimiento)
            ORDER BY fecha DESC NULLS LAST, id DESC
            LIMIT greatest(coalesce(p_limite, 50), 1)) m
      LEFT JOIN productos p ON p.id = m.producto_id
      LEFT JOIN documentos d ON d.id = m.documento_id
      LEFT JOIN formatos_documento f ON f.codigo = d.formato_codigo), '[]'::jsonb);
END;
$$;



CREATE FUNCTION public.portal_movimientos_resumen() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    RETURN jsonb_build_object(
      'mes_actual', (
        SELECT jsonb_build_object(
                 'ventas',  coalesce(sum(valor_total) FILTER (WHERE tipo = 'venta'),  0),
                 'compras', coalesce(sum(valor_total) FILTER (WHERE tipo = 'compra'), 0),
                 'movimientos', count(*))
        FROM movimientos
        WHERE negocio_id = v_negocio
          -- acotado por los dos lados: un archivo con fechas futuras (pasa, y
          -- los fixtures lo prueban) no debe inflar "este mes"
          AND fecha >= date_trunc('month', current_date)
          AND fecha <  date_trunc('month', current_date) + interval '1 month'),

      'meses', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
                 'mes', to_char(m.mes, 'YYYY-MM'),
                 'ventas', m.ventas, 'compras', m.compras,
                 'movimientos', m.n)
               ORDER BY m.mes DESC)
        FROM (SELECT date_trunc('month', fecha) AS mes,
                     coalesce(sum(valor_total) FILTER (WHERE tipo = 'venta'),  0) AS ventas,
                     coalesce(sum(valor_total) FILTER (WHERE tipo = 'compra'), 0) AS compras,
                     count(*) AS n
              FROM movimientos
              WHERE negocio_id = v_negocio AND fecha IS NOT NULL
              GROUP BY 1 ORDER BY 1 DESC LIMIT 12) m), '[]'::jsonb),

      -- Histórico completo a propósito: con pocos datos, un recorte de 90 días
      -- deja la pantalla vacía y parece que el sistema no sirve.
      -- Se agrupa por norm_texto: mientras matching no resuelva todas las
      -- líneas, "HUEVOS AA X30" (crudo) y "Huevos AA x30" (canónico) son el
      -- mismo producto y no deben salir dos veces. Para mostrar se prefiere el
      -- nombre canónico si alguna fila lo tiene.
      'top_productos', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
                 'nombre', t.nombre, 'cantidad', t.cantidad, 'total', t.total)
               ORDER BY t.total DESC NULLS LAST)
        FROM (SELECT coalesce(max(b.nombre) FILTER (WHERE b.canonico),
                              max(b.nombre)) AS nombre,
                     sum(b.cantidad) AS cantidad, sum(b.total) AS total
              FROM (SELECT coalesce(p.nombre_canonico,
                                    portal_mov_nombre(m.raw, f.mapeo),
                                    '(sin nombre)') AS nombre,
                           p.id IS NOT NULL AS canonico,
                           m.cantidad, m.valor_total AS total
                    FROM movimientos m
                    LEFT JOIN productos p ON p.id = m.producto_id
                    LEFT JOIN documentos d ON d.id = m.documento_id
                    LEFT JOIN formatos_documento f ON f.codigo = d.formato_codigo
                    WHERE m.negocio_id = v_negocio AND m.tipo = 'venta') b
              GROUP BY norm_texto(b.nombre)
              ORDER BY 3 DESC NULLS LAST LIMIT 8) t), '[]'::jsonb));
END;
$$;



CREATE FUNCTION public.portal_negocio() RETURNS bigint
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE v_id bigint := portal_claim('negocio_id');
BEGIN
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'sesión sin negocio' USING ERRCODE = '42501';
    END IF;
    RETURN v_id;
END;
$$;



CREATE FUNCTION public.portal_negocio_guardar(p_nit text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
DECLARE
    v_negocio bigint := portal_negocio();
    v_crudo   text := regexp_replace(coalesce(p_nit, ''), '[.\s]', '', 'g');
    v_base    text;
    v_dv      text;
BEGIN
    -- Borrar el NIT es legítimo (se escribió mal, el negocio cambió de figura).
    IF v_crudo = '' THEN
        UPDATE negocios SET nit = NULL WHERE id = v_negocio;
        RETURN jsonb_build_object('ok', true, 'nit', NULL);
    END IF;

    v_base := split_part(v_crudo, '-', 1);
    v_dv   := nullif(split_part(v_crudo, '-', 2), '');

    IF v_base !~ '^\d{5,15}$' THEN
        RETURN jsonb_build_object('ok', false, 'error',
                 'El NIT debe tener solo números (entre 5 y 15 dígitos), con o sin -DV.');
    END IF;

    IF v_dv IS NOT NULL AND v_dv <> nit_dv(v_base)::text THEN
        RETURN jsonb_build_object('ok', false, 'error',
                 format('El dígito de verificación no cuadra: para %s sería %s.',
                        v_base, nit_dv(v_base)));
    END IF;

    UPDATE negocios SET nit = v_base WHERE id = v_negocio;

    -- Con el NIT nuevo, las facturas DIAN ya ingeridas pueden cambiar de lado
    -- (compra -> venta). Se re-facturan acá mismo: es la misma función del
    -- backfill de la 036, actualiza en vez de duplicar y conserva los pagos.
    PERFORM cartera_refacturar(v_negocio);

    RETURN jsonb_build_object('ok', true, 'nit', v_base, 'dv', nit_dv(v_base));
END;
$_$;



CREATE FUNCTION public.portal_pago_registrar(p_factura_id bigint, p_valor numeric, p_fecha date DEFAULT NULL::date, p_medio text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_negocio bigint := portal_negocio();
    v_usuario bigint := portal_claim('usuario_id');
BEGIN
    IF NOT EXISTS (SELECT 1 FROM facturas
                   WHERE id = p_factura_id AND negocio_id = v_negocio) THEN
        RAISE EXCEPTION 'no existe esa factura' USING ERRCODE = '42501';
    END IF;

    RETURN pago_registrar(p_factura_id, p_valor, p_fecha, p_medio,
                          'portal', v_usuario);
END;
$$;



CREATE FUNCTION public.portal_pedido() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN pedido_sugerido(portal_negocio());
END;
$$;



CREATE FUNCTION public.portal_pendientes() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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



CREATE FUNCTION public.portal_perfil() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN perfil_negocio(portal_negocio());
END;
$$;



CREATE FUNCTION public.portal_productos() RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'id', p.id, 'nombre', p.nombre_canonico, 'unidad', p.unidad,
             'stock', b.balance, 'origen_stock', b.origen_stock,
             'conteo_fecha', b.conteo_fecha)
             ORDER BY p.nombre_canonico), '[]'::jsonb)
    FROM productos p
    LEFT JOIN v_balance_unidades b
           ON b.negocio_id = p.negocio_id AND b.producto_id = p.id
    WHERE p.negocio_id = portal_negocio();
$$;



CREATE FUNCTION public.portal_recomendacion_accion(p_id bigint, p_accion text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
    RETURN recomendacion_accion(p_id, portal_negocio(), p_accion, NULL);
END;
$$;



CREATE FUNCTION public.portal_recomendaciones(p_limite integer DEFAULT 50) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    RETURN jsonb_build_object(
      'vigentes', recomendaciones_vigentes(v_negocio, p_limite),
      -- Las cerradas son la mitad interesante: "esto te lo dije y se arregló".
      'cerradas', coalesce((
         SELECT jsonb_agg(jsonb_build_object(
                  'id', id, 'titulo', titulo, 'impacto', impacto,
                  'icono', icono,
                  'estado', estado, 'cerrada_por', cerrada_por,
                  'resultado', resultado,
                  'cambio_pct', datos ->> 'cambio_pct',
                  'detectada_en', detectada_en, 'cerrada_en', cerrada_en)
                  ORDER BY cerrada_en DESC)
         FROM (SELECT * FROM recomendaciones
                WHERE negocio_id = v_negocio AND estado NOT IN ('nueva','vigente')
                ORDER BY cerrada_en DESC LIMIT p_limite) c), '[]'::jsonb));
END;
$$;



CREATE FUNCTION public.portal_sesion_abrir(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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



CREATE FUNCTION public.portal_snapshots(p_limite integer DEFAULT 24) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    RETURN coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'fecha', fecha,
               'periodo_desde', lower(periodo), 'periodo_hasta', upper(periodo),
               'origen', origen,
               'parcial', coalesce((metricas -> 'parcial')::boolean, false),
               'salud', salud,
               'ventas',  metricas #> '{totales,ventas}',
               'compras', metricas #> '{totales,compras}',
               'productos', metricas #> '{productos,total}',
               'margen_promedio_pct', metricas #> '{productos,margen_promedio_pct}')
               ORDER BY fecha DESC)
      FROM (SELECT * FROM snapshots_negocio
             WHERE negocio_id = v_negocio
             ORDER BY fecha DESC LIMIT p_limite) s), '[]'::jsonb);
END;
$$;



CREATE FUNCTION public.portal_token_crear(p_usuario_id bigint, p_minutos integer DEFAULT 15) RETURNS text
    LANGUAGE plpgsql
    AS $$
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



CREATE FUNCTION public.recomendacion_accion(p_reco_id bigint, p_negocio_id bigint, p_accion text, p_usuario_id bigint DEFAULT NULL::bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $_$
DECLARE
    v_r      record;
    v_precio numeric;
BEGIN
    SELECT * INTO v_r FROM recomendaciones
    WHERE id = p_reco_id AND negocio_id = p_negocio_id
      AND estado IN ('nueva','vigente');

    IF v_r.id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_encontrada');
    END IF;

    -- >>> 066: la foto ANTES de cerrar. Después de cerrar da lo mismo, pero
    -- hacerlo antes deja el orden explícito y a prueba de reordenamientos.
    PERFORM recomendacion_marcar_cierre(p_reco_id);

    IF p_accion = 'hice' THEN
        UPDATE recomendaciones
           SET estado = 'resuelta', cerrada_por = 'accion_usuario',
               cerrada_en = now()
         WHERE id = p_reco_id;
        RETURN jsonb_build_object('ok', true, 'accion', 'hice',
                                  'titulo', v_r.titulo);

    ELSIF p_accion = 'no_aplica' THEN
        UPDATE recomendaciones
           SET estado = 'ignorada', cerrada_por = 'accion_usuario',
               cerrada_en = now()
         WHERE id = p_reco_id;
        RETURN jsonb_build_object('ok', true, 'accion', 'no_aplica',
                                  'titulo', v_r.titulo);

    ELSIF p_accion = 'precio' THEN
        v_precio := nullif(v_r.datos ->> 'precio_sugerido', '')::numeric;
        IF v_precio IS NULL OR v_precio <= 0 THEN
            RETURN jsonb_build_object('ok', false, 'error', 'sin_precio');
        END IF;

        PERFORM conocimiento_guardar(
          p_negocio_id, 'precio', v_r.titulo,
          format('Precio sugerido por Chasqui a partir de %s.', v_r.regla),
          v_r.titulo,
          jsonb_build_object('valor', v_precio, 'origen', 'recomendacion',
                             'recomendacion_id', p_reco_id),
          'chat', p_usuario_id);

        UPDATE recomendaciones
           SET estado = 'resuelta', cerrada_por = 'accion_usuario',
               cerrada_en = now()
         WHERE id = p_reco_id;

        RETURN jsonb_build_object('ok', true, 'accion', 'precio',
                                  'titulo', v_r.titulo,
                                  'precio', '$' || miles(v_precio));
    END IF;

    RETURN jsonb_build_object('ok', false, 'error', 'accion_desconocida');
END;
$_$;



CREATE FUNCTION public.recomendacion_marcar_cierre(p_reco_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_r record;
    v_m record;
    v_v numeric;
BEGIN
    SELECT * INTO v_r FROM recomendaciones WHERE id = p_reco_id;
    IF v_r.id IS NULL THEN RETURN; END IF;

    SELECT * INTO v_m FROM metricas_resultado WHERE regla = v_r.regla;
    IF v_m.regla IS NULL THEN RETURN; END IF;   -- regla sin métrica: no se mide

    -- Las magnitudes de flujo se miden DESDE el cierre, así que su valor al
    -- cerrar es cero por definición: lo que se cuenta es lo que pase después.
    IF v_m.metrica IN ('unidades_vendidas','ventas') THEN
        v_v := 0;
    ELSE
        v_v := recomendacion_metrica_valor(v_r.negocio_id, v_r.clave_objeto,
                                           v_m.metrica);
    END IF;

    UPDATE recomendaciones
       SET datos = coalesce(datos, '{}'::jsonb)
                   || jsonb_build_object('valor_al_cerrar', v_v,
                                         'metrica_resultado', v_m.metrica)
     WHERE id = p_reco_id;
END;
$$;



CREATE FUNCTION public.recomendacion_metrica_valor(p_negocio_id bigint, p_clave text, p_metrica text, p_desde date DEFAULT NULL::date) RETURNS numeric
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_prod bigint := CASE WHEN p_clave LIKE 'producto:%'
                          THEN nullif(split_part(p_clave, ':', 2), '')::bigint END;
    v_terc bigint := CASE WHEN p_clave LIKE 'tercero:%'
                          THEN nullif(split_part(p_clave, ':', 2), '')::bigint END;
    v_val  numeric;
BEGIN
    IF p_metrica = 'costo' THEN
        SELECT costo_actual INTO v_val FROM v_margen_producto
        WHERE negocio_id = p_negocio_id AND producto_id = v_prod;

    ELSIF p_metrica = 'margen_pct' THEN
        SELECT margen_pct INTO v_val FROM v_margen_producto
        WHERE negocio_id = p_negocio_id AND producto_id = v_prod;

    ELSIF p_metrica = 'dias_cobertura' THEN
        SELECT dias_cobertura INTO v_val FROM v_rotacion_producto
        WHERE negocio_id = p_negocio_id AND producto_id = v_prod;

    ELSIF p_metrica = 'balance' THEN
        SELECT balance INTO v_val FROM v_balance_unidades
        WHERE negocio_id = p_negocio_id AND producto_id = v_prod;

    ELSIF p_metrica = 'unidades_vendidas' THEN
        SELECT coalesce(sum(cantidad), 0) INTO v_val FROM mov_visibles
        WHERE negocio_id = p_negocio_id AND tipo = 'venta'
          AND producto_id = v_prod
          AND (p_desde IS NULL OR fecha >= p_desde);

    ELSIF p_metrica = 'ventas' THEN
        SELECT coalesce(sum(valor_total), 0) INTO v_val FROM mov_visibles
        WHERE negocio_id = p_negocio_id AND tipo = 'venta'
          AND (p_desde IS NULL OR fecha >= p_desde);

    ELSIF p_metrica = 'concentracion_pct' THEN
        SELECT max(gasto) * 100.0 / nullif(sum(gasto), 0) INTO v_val
        FROM (SELECT nullif(btrim(coalesce(raw ->> 'proveedor','')),'') AS prov,
                     sum(valor_total) AS gasto
              FROM mov_visibles
              WHERE negocio_id = p_negocio_id AND tipo = 'compra'
                AND nullif(btrim(coalesce(raw ->> 'proveedor','')),'') IS NOT NULL
              GROUP BY 1) g;

    -- >>> 069: lo que ese cliente todavía debe y ya venció.
    ELSIF p_metrica = 'saldo_vencido' THEN
        SELECT coalesce(sum(saldo), 0) INTO v_val FROM facturas
        WHERE negocio_id = p_negocio_id AND tercero_id = v_terc
          AND tipo = 'venta' AND saldo > 0
          AND vencimiento IS NOT NULL AND vencimiento < current_date;
    END IF;

    RETURN v_val;
END;
$$;



CREATE FUNCTION public.recomendacion_objeto_evaluable(p_negocio_id bigint, p_clave text) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
    SELECT CASE
      WHEN p_clave = 'negocio' THEN EXISTS (
             SELECT 1 FROM mov_visibles WHERE negocio_id = p_negocio_id)
      WHEN p_clave LIKE 'producto:%' THEN EXISTS (
             SELECT 1 FROM mov_visibles
              WHERE negocio_id = p_negocio_id
                AND producto_id = nullif(split_part(p_clave, ':', 2), '')::bigint)
      WHEN p_clave LIKE 'proveedor:%' THEN EXISTS (
             SELECT 1 FROM mov_visibles
              WHERE negocio_id = p_negocio_id AND tipo = 'compra'
                AND btrim(coalesce(raw ->> 'proveedor', '')) = substring(p_clave FROM 11))
      -- >>> 069: el tercero sigue siendo evaluable mientras exista como
      -- tercero, tenga o no facturas abiertas. Que ya no deba nada es
      -- justamente el caso "se resolvió".
      WHEN p_clave LIKE 'tercero:%' THEN EXISTS (
             SELECT 1 FROM terceros
              WHERE negocio_id = p_negocio_id
                AND id = nullif(split_part(p_clave, ':', 2), '')::bigint)
      ELSE false
    END;
$$;



CREATE FUNCTION public.recomendaciones_medir(p_negocio_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    r        record;
    v_ahora  numeric;
    v_antes  numeric;
    v_delta  numeric;
    v_res    text;
    v_n      jsonb := jsonb_build_object('positivo', 0, 'neutro', 0,
                                         'negativo', 0, 'sin_datos', 0);
BEGIN
    FOR r IN
        SELECT re.*, m.metrica, m.direccion, m.umbral_pct
        FROM recomendaciones re
        JOIN metricas_resultado m ON m.regla = re.regla
        WHERE re.negocio_id = p_negocio_id
          AND re.estado NOT IN ('nueva','vigente')
          AND re.resultado IS NULL
          AND re.cerrada_en IS NOT NULL
          AND re.datos ? 'valor_al_cerrar'
    LOOP
        -- ¿Llegaron datos después del cierre? Se mira `creado_en` y NO `fecha`:
        -- un archivo con ventas fechadas la semana que viene ya estaba cargado
        -- cuando se cerró la recomendación, así que no dice nada sobre si la
        -- acción sirvió. Lo que importa es que haya entrado información nueva,
        -- no que haya filas con fecha posterior.
        IF NOT EXISTS (SELECT 1 FROM mov_visibles
                        WHERE negocio_id = p_negocio_id
                          AND creado_en > r.cerrada_en) THEN
            v_n := jsonb_set(v_n, '{sin_datos}',
                     to_jsonb((v_n ->> 'sin_datos')::int + 1));
            CONTINUE;
        END IF;

        v_antes := nullif(r.datos ->> 'valor_al_cerrar', '')::numeric;
        v_ahora := recomendacion_metrica_valor(p_negocio_id, r.clave_objeto,
                                               r.metrica, r.cerrada_en::date);

        IF v_ahora IS NULL OR v_antes IS NULL THEN
            v_n := jsonb_set(v_n, '{sin_datos}',
                     to_jsonb((v_n ->> 'sin_datos')::int + 1));
            CONTINUE;
        END IF;

        -- Cambio relativo. Con un valor de partida en cero —el caso de las
        -- magnitudes de flujo— cualquier movimiento es 100%: es lo correcto,
        -- porque ahí la pregunta es "¿pasó algo?" y no "¿cuánto cambió?".
        v_delta := CASE WHEN coalesce(v_antes, 0) = 0
                        THEN CASE WHEN v_ahora = 0 THEN 0 ELSE 100 END
                        ELSE (v_ahora - v_antes) * 100.0 / abs(v_antes) END;

        v_res := CASE
          WHEN abs(v_delta) < r.umbral_pct THEN 'neutro'
          WHEN (r.direccion = 'sube_mejor' AND v_delta > 0)
            OR (r.direccion = 'baja_mejor' AND v_delta < 0) THEN 'positivo'
          ELSE 'negativo' END;

        UPDATE recomendaciones
           SET resultado = v_res,
               datos = coalesce(datos, '{}'::jsonb) || jsonb_build_object(
                         'valor_al_medir', round(v_ahora, 4),
                         'cambio_pct', round(v_delta, 1),
                         'medido_en', current_date)
         WHERE id = r.id;

        v_n := jsonb_set(v_n, ARRAY[v_res], to_jsonb((v_n ->> v_res)::int + 1));
    END LOOP;

    RETURN v_n;
END;
$$;



CREATE FUNCTION public.recomendaciones_negocio(p_negocio_id bigint, p_registro boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $_$
DECLARE
    v_margen_min   numeric := coalesce((parametro(p_negocio_id,'margen_minimo_pct'))::text::numeric, 20);
    v_deriva_ali   numeric := coalesce((parametro(p_negocio_id,'deriva_costo_alerta_pct'))::text::numeric, 8);
    v_dias_cob     numeric := coalesce((parametro(p_negocio_id,'dias_cobertura_min'))::text::numeric, 7);
    v_entrega      numeric := coalesce((parametro(p_negocio_id,'dias_entrega_proveedor'))::text::numeric, 4);
    v_seguridad    numeric := coalesce((parametro(p_negocio_id,'dias_stock_seguridad'))::text::numeric, 3);
    v_lenta        numeric := coalesce((parametro(p_negocio_id,'rotacion_lenta_dias'))::text::numeric, 60);
    v_margen_alto  numeric := coalesce((parametro(p_negocio_id,'margen_alto_pct'))::text::numeric, 35);
    v_dep_prov     numeric := coalesce((parametro(p_negocio_id,'dependencia_proveedor_pct'))::text::numeric, 50);
    v_pri_alta     numeric := coalesce((parametro(p_negocio_id,'prioridad_alta_pct'))::text::numeric, 2);
    v_pri_media    numeric := coalesce((parametro(p_negocio_id,'prioridad_media_pct'))::text::numeric, 0.5);
    -- >>> 055: la vara propia de cada tipo de impacto.
    v_pri_alta_u   numeric := coalesce((parametro(p_negocio_id,'prioridad_alta_unico_pct'))::text::numeric, 10);
    v_pri_media_u  numeric := coalesce((parametro(p_negocio_id,'prioridad_media_unico_pct'))::text::numeric, 3);
    v_pri_alta_k   numeric := coalesce((parametro(p_negocio_id,'prioridad_alta_capital_pct'))::text::numeric, 50);
    v_pri_media_k  numeric := coalesce((parametro(p_negocio_id,'prioridad_media_capital_pct'))::text::numeric, 20);
    -- >>> 060: los umbrales de las reglas comparativas.
    v_sin_venta    numeric := coalesce((parametro(p_negocio_id,'dias_sin_venta_alerta'))::text::numeric, 45);
    v_min_ventas   numeric := coalesce((parametro(p_negocio_id,'ventas_minimas_historicas'))::text::numeric, 3);
    v_subidas      numeric := coalesce((parametro(p_negocio_id,'subidas_proveedor_alerta'))::text::numeric, 3);
    v_caida_margen numeric := coalesce((parametro(p_negocio_id,'caida_margen_pp_alerta'))::text::numeric, 3);
    v_caida_anual  numeric := coalesce((parametro(p_negocio_id,'caida_anual_pct_alerta'))::text::numeric, 15);
    -- >>> 069: cartera.
    v_mora_dias    numeric := coalesce((parametro(p_negocio_id,'cartera_mora_dias'))::text::numeric, 15);
    v_meses        numeric;
    v_base_mes     numeric;   -- lo que mueve el negocio en un mes
    v_desde        date;
    v_hasta        date;      -- el "hoy" del análisis: la fecha más reciente
    v_mes_ref      date;      -- último mes COMPLETO de datos
    v_out          jsonb;
BEGIN
    -- Ventana real de los datos. Todo lo "por mes" se escala con esto, así que
    -- un negocio que cargó 15 días no ve cifras infladas ni desinfladas.
    SELECT min(fecha), max(fecha) INTO v_desde, v_hasta
    FROM mov_visibles WHERE negocio_id = p_negocio_id AND fecha IS NOT NULL;
    v_meses := coalesce(greatest((v_hasta - v_desde)::numeric / 30.0, 1), 1);

    -- >>> 060. El "hoy" de las reglas comparativas es `v_hasta`, no
    -- `current_date`. Un negocio que sube en agosto un archivo que termina en
    -- mayo no tiene tres meses sin vender: tiene tres meses sin cargar. Medir
    -- contra el reloj en vez de contra los datos convertiría cada carga
    -- atrasada en una avalancha de alertas falsas.
    --
    -- El mes de referencia es el último COMPLETO: comparar un agosto a medias
    -- contra un agosto entero del año pasado siempre daría caída.
    v_mes_ref := CASE
        WHEN v_hasta >= (date_trunc('month', v_hasta) + interval '1 month - 1 day')::date
        THEN date_trunc('month', v_hasta)::date
        ELSE (date_trunc('month', v_hasta) - interval '1 month')::date END;

    SELECT greatest(coalesce(sum(valor_total) FILTER (WHERE tipo = 'venta'),
                             sum(valor_total) FILTER (WHERE tipo = 'compra'), 0) / v_meses, 1)
      INTO v_base_mes
    FROM mov_visibles WHERE negocio_id = p_negocio_id;

    WITH
    -- Unidades compradas y vendidas por producto.
    base AS (
        SELECT m.producto_id,
               sum(m.cantidad) FILTER (WHERE m.tipo = 'compra') AS u_compradas,
               sum(m.cantidad) FILTER (WHERE m.tipo = 'venta')  AS u_vendidas
        FROM mov_visibles m
        WHERE m.negocio_id = p_negocio_id AND m.producto_id IS NOT NULL
        GROUP BY 1
    ),
    -- Precio promedio por proveedor, para saber si hay dónde comprar más barato.
    por_proveedor AS (
        SELECT m.producto_id,
               nullif(btrim(coalesce(m.raw ->> 'proveedor', '')), '') AS proveedor,
               sum(m.cantidad)                                        AS u,
               sum(m.valor_total) / nullif(sum(m.cantidad), 0)        AS precio_prom
        FROM mov_visibles m
        WHERE m.negocio_id = p_negocio_id AND m.tipo = 'compra'
          AND m.producto_id IS NOT NULL AND m.cantidad > 0 AND m.valor_total > 0
        GROUP BY 1, 2
    ),
    alternativa AS (
        SELECT producto_id,
               (array_agg(proveedor ORDER BY precio_prom))[1] AS prov_barato,
               round(min(precio_prom))                        AS precio_mejor,
               round(sum(u * precio_prom) / nullif(sum(u), 0)) AS precio_pagado,
               sum(u)                                         AS u_total
        FROM por_proveedor
        WHERE proveedor IS NOT NULL
        GROUP BY 1
        HAVING count(DISTINCT proveedor) > 1
    ),

    -- R1. El costo subió -----------------------------------------------------
    -- Tipo `mensual`: el sobrecosto se repite en cada compra futura.
    -- Las opciones se arman con unnest + agregado, no con jsonb_strip_nulls:
    -- strip_nulls solo borra campos NULL de OBJETOS, no elementos de un array,
    -- así que una opción que no aplica dejaría un `null` suelto en la lista.
    r_costo AS (
        SELECT 'costo' AS regla, ('producto:' || d.producto_id) AS clave_objeto,
               '📈' AS icono, p.nombre_canonico AS titulo,
               round(coalesce(d.costo_fin - d.costo_ini, 0)
                     * coalesce(b.u_compradas, 0) / v_meses) AS impacto_mes,
               'mensual'::text AS impacto_tipo,
               CASE WHEN round(coalesce(d.costo_fin - d.costo_ini, 0)
                               * coalesce(b.u_compradas, 0) / v_meses) > 0
                    THEN format('Al ritmo que lo comprás, son unos $%s más al mes.',
                                miles(round((d.costo_fin - d.costo_ini)
                                            * b.u_compradas / v_meses)))
                    ELSE '' END AS impacto_txt,
               format('El costo pasó de $%s a $%s: subió %s%% desde tu primera compra.',
                      miles(d.costo_ini), miles(d.costo_fin), fmt_decimal(d.deriva_pct))
               || CASE WHEN mp.precio_actual IS NOT NULL AND mp.precio_actual > 0
                       THEN format(' Con tu precio de venta actual el margen te queda en %s%%.',
                                   fmt_decimal(mp.margen_pct))
                       ELSE '' END AS problema,
               (SELECT coalesce(jsonb_agg(x), '[]'::jsonb) FROM unnest(ARRAY[
                  'Negociá el precio con tu proveedor antes de la próxima compra.'::text,
                  CASE WHEN a.prov_barato IS NOT NULL AND a.precio_mejor < d.costo_fin
                       THEN format('Comprale a %s, que te lo dejó a $%s.',
                                   a.prov_barato, miles(a.precio_mejor)) END,
                  CASE WHEN mp.precio_actual IS NOT NULL AND mp.precio_actual > 0
                            AND mp.margen_pct < v_margen_min
                       THEN format('Si no conseguís mejor precio, subí el precio de venta a $%s para volver a un margen de %s%%.',
                                   miles(round(d.costo_fin / nullif(1 - v_margen_min/100, 0))),
                                   fmt_decimal(v_margen_min)) END
                ]) AS x WHERE x IS NOT NULL) AS opciones,
               NULL::text AS origen_stock,
               -- >>> 064: lo mismo que dice la opción, pero como dato. El texto
               -- es para el dueño; esto es para que D1 pueda APLICARLO sin
               -- parsear una frase, que es la clase de cosa que se rompe la
               -- primera vez que alguien reescribe el copy.
               CASE WHEN mp.precio_actual IS NOT NULL AND mp.precio_actual > 0
                         AND mp.margen_pct < v_margen_min
                    THEN jsonb_build_object('precio_sugerido',
                           round(d.costo_fin / nullif(1 - v_margen_min/100, 0)))
                    ELSE '{}'::jsonb END AS datos
        FROM v_deriva_costo d
        JOIN productos p ON p.id = d.producto_id
        LEFT JOIN base b ON b.producto_id = d.producto_id
        LEFT JOIN alternativa a ON a.producto_id = d.producto_id
        LEFT JOIN v_margen_producto mp
               ON mp.producto_id = d.producto_id AND mp.negocio_id = d.negocio_id
        WHERE d.negocio_id = p_negocio_id AND d.deriva_pct >= v_deriva_ali
    ),

    -- R2. Estás pagando más de lo que ya conseguiste ------------------------
    -- Tipo `mensual`: la diferencia se paga en cada compra mientras no se cambie.
    r_proveedor AS (
        SELECT 'proveedor' AS regla, ('producto:' || a.producto_id) AS clave_objeto,
               '🧾' AS icono, p.nombre_canonico AS titulo,
               round((a.precio_pagado - a.precio_mejor) * a.u_total / v_meses) AS impacto_mes,
               'mensual'::text AS impacto_tipo,
               format('Estás dejando ir unos $%s al mes por comprarlo más caro de lo que ya lo conseguiste.',
                      miles(round((a.precio_pagado - a.precio_mejor) * a.u_total / v_meses))) AS impacto_txt,
               format('En promedio lo pagás a $%s, pero %s te lo dejó a $%s.',
                      miles(a.precio_pagado), a.prov_barato, miles(a.precio_mejor)) AS problema,
               jsonb_build_array(
                 format('Concentrá la compra de este producto en %s.', a.prov_barato),
                 'Usá ese precio como referencia para negociar con los demás.') AS opciones,
               NULL::text AS origen_stock,
               jsonb_build_object('proveedor_sugerido', a.prov_barato,
                                  'precio_mejor', a.precio_mejor) AS datos
        FROM alternativa a
        JOIN productos p ON p.id = a.producto_id
        WHERE a.precio_pagado > a.precio_mejor * 1.05
    ),

    -- R3. Margen por debajo del mínimo ---------------------------------------
    -- Tipo `mensual`: se deja de ganar en cada venta, mes tras mes.
    r_margen AS (
        SELECT 'margen' AS regla, ('producto:' || mp.producto_id) AS clave_objeto,
               '⚠️' AS icono, mp.nombre_canonico AS titulo,
               round(greatest(round(mp.costo_actual / nullif(1 - v_margen_min/100, 0))
                              - mp.precio_actual, 0)
                     * coalesce(b.u_vendidas, 0) / v_meses) AS impacto_mes,
               'mensual'::text AS impacto_tipo,
               CASE WHEN coalesce(b.u_vendidas, 0) > 0
                    THEN format('Son unos $%s al mes que no estás ganando.',
                                miles(round(greatest(round(mp.costo_actual / nullif(1 - v_margen_min/100, 0))
                                                     - mp.precio_actual, 0)
                                            * b.u_vendidas / v_meses)))
                    ELSE '' END AS impacto_txt,
               format('Lo vendés a $%s y te cuesta $%s: te deja %s%% de margen, por debajo del %s%% que deberías sostener.',
                      miles(mp.precio_actual), miles(mp.costo_actual),
                      fmt_decimal(mp.margen_pct), fmt_decimal(v_margen_min)) AS problema,
               jsonb_build_array(
                 format('Subilo a $%s y quedás en %s%% de margen.',
                        miles(round(mp.costo_actual / nullif(1 - v_margen_min/100, 0))),
                        fmt_decimal(v_margen_min)),
                 'Si no podés subir el precio, negociá el costo o buscá otra marca equivalente.') AS opciones,
               NULL::text AS origen_stock,
               jsonb_build_object('precio_sugerido',
                 round(mp.costo_actual / nullif(1 - v_margen_min/100, 0))) AS datos
        FROM v_margen_producto mp
        LEFT JOIN base b ON b.producto_id = mp.producto_id
        WHERE mp.negocio_id = p_negocio_id
          AND mp.precio_actual IS NOT NULL AND mp.precio_actual > 0
          AND mp.costo_actual IS NOT NULL
          AND mp.margen_pct < v_margen_min
    ),

    -- R4. Se agota, y cuánto comprar ----------------------------------------
    -- Tipo `unico`: es el lucro cesante de UN ciclo de entrega. Si se repone a
    -- tiempo no vuelve a ocurrir; no es una fuga mensual.
    -- La cantidad es la del ciclo completo: lo que se vende mientras el
    -- proveedor entrega, más el colchón. Es la cuenta que un tendero no hace y
    -- que decide entre quedarse sin producto o dormir la plata.
    r_agota AS (
        SELECT 'agota' AS regla, ('producto:' || r.producto_id) AS clave_objeto,
               '🕐' AS icono, p.nombre_canonico AS titulo,
               round(r.unidades_por_dia * v_entrega
                     * coalesce(mp.precio_actual, 0)) AS impacto_mes,
               'unico'::text AS impacto_tipo,
               CASE WHEN coalesce(mp.precio_actual, 0) > 0
                    THEN format('Si te quedás sin producto, son unos $%s que dejás de vender mientras llega el pedido.',
                                miles(round(r.unidades_por_dia * v_entrega * mp.precio_actual)))
                    ELSE '' END AS impacto_txt,
               -- Cobertura negativa = vendió más unidades de las que registró
               -- comprando. Decir "te alcanza para -95 días" no significa nada;
               -- lo que pasa es que ya no queda o falta cargar compras.
               CASE WHEN r.dias_cobertura < 0
                    THEN format('Por lo que cargaste ya no te queda: vendiste más de lo que registraste comprando. Vendés %s por día.',
                                unidades_es(r.unidades_por_dia))
                    ELSE format('Te alcanza para %s días y vendés %s por día.',
                                fmt_decimal(r.dias_cobertura),
                                unidades_es(r.unidades_por_dia))
               END
               || CASE WHEN r.origen_stock = 'estimado'
                       THEN ' Ojo: es una estimación de lo comprado menos lo vendido, no un conteo tuyo.'
                       ELSE '' END AS problema,
               jsonb_build_array(
                 format('Pedí %s: es lo que vendés en los %s días que demora el proveedor más %s días de colchón.',
                        unidades_es(ceil(r.unidades_por_dia * (v_entrega + v_seguridad))),
                        fmt_decimal(v_entrega), fmt_decimal(v_seguridad)),
                 'Si el proveedor demora más de lo normal, pedí antes, no más cantidad.') AS opciones,
               r.origen_stock,
               -- La cantidad a pedir, ya calculada: es lo que consume D2 para
               -- armar la lista de compra.
               jsonb_build_object('unidades_pedir',
                 ceil(r.unidades_por_dia * (v_entrega + v_seguridad))) AS datos
        FROM v_rotacion_producto r
        JOIN productos p ON p.id = r.producto_id
        LEFT JOIN v_margen_producto mp
               ON mp.producto_id = r.producto_id AND mp.negocio_id = r.negocio_id
        WHERE r.negocio_id = p_negocio_id
          AND r.dias_cobertura IS NOT NULL AND r.dias_cobertura < v_dias_cob
          AND r.unidades_por_dia > 0
    ),

    -- R5. Plata quieta: mucho inventario para lo que rota --------------------
    -- Tipo `capital`: no es plata que se pierde, es plata que existe y está
    -- inmóvil. Por eso su vara es varias veces más alta que la de una fuga.
    r_quieto AS (
        SELECT 'quieto' AS regla, ('producto:' || r.producto_id) AS clave_objeto,
               CASE WHEN mp.margen_pct >= v_margen_alto THEN '💰' ELSE '📦' END AS icono,
               p.nombre_canonico AS titulo,
               round(bal.balance * coalesce(mp.costo_actual, 0)) AS impacto_mes,
               'capital'::text AS impacto_tipo,
               CASE WHEN coalesce(mp.costo_actual, 0) > 0
                    THEN format('Tenés $%s inmovilizados en esa mercancía.',
                                miles(round(bal.balance * mp.costo_actual)))
                    ELSE '' END AS impacto_txt,
               format('Tenés inventario para %s días y solo vendés %s unidades por día.',
                      fmt_decimal(r.dias_cobertura), fmt_decimal(r.unidades_por_dia))
               || CASE WHEN bal.origen_stock = 'estimado'
                       THEN ' Ojo: es una estimación de lo comprado menos lo vendido, no un conteo tuyo.'
                       ELSE '' END AS problema,
               CASE WHEN mp.margen_pct >= v_margen_alto
                    THEN jsonb_build_array(
                           format('Te deja %s%% de margen: empujalo con una promoción o ponelo a la vista, en vez de rematarlo.',
                                  fmt_decimal(mp.margen_pct)),
                           'No vuelvas a comprarlo hasta bajar lo que tenés.')
                    ELSE jsonb_build_array(
                           'No vuelvas a comprarlo hasta agotar lo que tenés.',
                           'Si sigue sin moverse, sacalo con descuento antes de que se venza o pase de moda.')
               END AS opciones,
               bal.origen_stock,
               '{}'::jsonb AS datos
        FROM v_rotacion_producto r
        JOIN productos p ON p.id = r.producto_id
        JOIN v_balance_unidades bal
          ON bal.producto_id = r.producto_id AND bal.negocio_id = r.negocio_id
        LEFT JOIN v_margen_producto mp
               ON mp.producto_id = r.producto_id AND mp.negocio_id = r.negocio_id
        WHERE r.negocio_id = p_negocio_id
          AND r.dias_cobertura IS NOT NULL AND r.dias_cobertura > v_lenta
          AND bal.balance > 0
    ),

    -- R6. Un solo proveedor concentra las compras ----------------------------
    -- Tipo `mensual` con impacto 0: es un riesgo, no una pérdida en curso. El
    -- tipo da igual para la prioridad —entra fija en media— pero se declara
    -- para que ningún consumidor futuro tenga que tratarla como excepción.
    gasto_prov AS (
        SELECT nullif(btrim(coalesce(m.raw ->> 'proveedor', '')), '') AS proveedor,
               sum(m.valor_total) AS gasto
        FROM mov_visibles m
        WHERE m.negocio_id = p_negocio_id AND m.tipo = 'compra'
        GROUP BY 1
    ),
    r_dependencia AS (
        SELECT 'dependencia' AS regla, ('proveedor:' || g.proveedor) AS clave_objeto,
               '🔎' AS icono, 'Dependés de un solo proveedor' AS titulo,
               0::numeric AS impacto_mes, 'mensual'::text AS impacto_tipo, '' AS impacto_txt,
               format('%s concentra el %s%% de todo lo que comprás ($%s).',
                      g.proveedor,
                      fmt_decimal(round(g.gasto * 100.0 / nullif(t.total, 0), 1)),
                      miles(round(g.gasto))) AS problema,
               jsonb_build_array(
                 'Conseguí un segundo proveedor para los productos que más te pesan, aunque le compres poco.',
                 'Con dos precios en la mano tenés con qué negociar; con uno solo, aceptás lo que te digan.') AS opciones,
               NULL::text AS origen_stock,
               '{}'::jsonb AS datos
        FROM gasto_prov g,
             LATERAL (SELECT sum(gasto) AS total FROM gasto_prov) t
        WHERE g.proveedor IS NOT NULL AND t.total > 0
          AND g.gasto * 100.0 / t.total >= v_dep_prov
    ),

    -- =====================================================================
    -- NIVEL 1 COMPLETO (060): reglas contra el propio historial del negocio
    -- =====================================================================
    -- Las seis de arriba miran una foto: cómo está el negocio hoy. Estas cuatro
    -- miran la película. Tres de ellas se calculan directamente sobre
    -- `mov_visibles` y no sobre los snapshots, a propósito: un hecho que está en
    -- los movimientos —cuándo fue la última venta, qué precio pagó cada compra—
    -- es más preciso ahí, y sobre todo no depende de cada cuánto se corrieron
    -- análisis. Solo el margen necesita snapshots, porque un margen no es un
    -- hecho registrado sino una medición: sale de comparar el costo y el precio
    -- vigentes en un momento, y ese momento hay que haberlo guardado.

    -- R7. Dejó de venderse -------------------------------------------------
    -- El producto tenía ritmo y se paró. Es la regla que un dueño agradece
    -- porque el producto que no se vende no molesta: simplemente desaparece de
    -- la vista mientras ocupa plata y espacio.
    venta_hist AS (
        SELECT m.producto_id,
               min(m.fecha) AS primera, max(m.fecha) AS ultima,
               count(*)     AS n_ventas,
               sum(m.valor_total) AS importe
        FROM mov_visibles m
        WHERE m.negocio_id = p_negocio_id AND m.tipo = 'venta'
          AND m.producto_id IS NOT NULL AND m.fecha IS NOT NULL
        GROUP BY 1
    ),
    r_sin_ventas AS (
        SELECT 'sin_ventas' AS regla, ('producto:' || v.producto_id) AS clave_objeto,
               '📉' AS icono, p.nombre_canonico AS titulo,
               -- Lo que dejó de entrar por mes, medido con su propio ritmo
               -- mientras se vendía, no con el del negocio entero.
               round(v.importe / greatest((v.ultima - v.primera)::numeric / 30.0, 1)) AS impacto_mes,
               'mensual'::text AS impacto_tipo,
               format('Mientras se vendía te entraban unos $%s al mes por ese producto.',
                      miles(round(v.importe / greatest((v.ultima - v.primera)::numeric / 30.0, 1)))) AS impacto_txt,
               format('Lo vendiste %s veces y la última fue el %s: van %s días sin moverse.',
                      v.n_ventas, to_char(v.ultima, 'DD/MM/YYYY'), (v_hasta - v.ultima)) AS problema,
               jsonb_build_array(
                 'Fijate si todavía lo tenés en el mostrador y a la vista: lo que no se ve no se vende.',
                 'Si dejaste de conseguirlo o lo sacaste vos, ignorá este aviso; si no, algo cambió y conviene saber qué.') AS opciones,
               NULL::text AS origen_stock,
               '{}'::jsonb AS datos
        FROM venta_hist v
        JOIN productos p ON p.id = v.producto_id
        WHERE (v_hasta - v.ultima) > v_sin_venta
          AND v.n_ventas >= v_min_ventas
          -- Sin un historial que dé para medir un ritmo, "dejó de venderse" no
          -- significa nada: puede no haber empezado nunca.
          AND (v.ultima - v.primera) >= 14
    ),

    -- R8. El proveedor viene subiendo --------------------------------------
    -- Distinta de R1: R1 dice que el costo está más alto que al principio, que
    -- puede ser un salto único. Esta dice que sube UNA Y OTRA VEZ con el mismo
    -- proveedor, que es un patrón de negociación y se responde distinto.
    compras_serie AS (
        SELECT m.producto_id,
               nullif(btrim(coalesce(m.raw ->> 'proveedor', '')), '') AS proveedor,
               m.fecha, m.cantidad,
               m.valor_total / nullif(m.cantidad, 0) AS precio
        FROM mov_visibles m
        WHERE m.negocio_id = p_negocio_id AND m.tipo = 'compra'
          AND m.producto_id IS NOT NULL AND m.cantidad > 0 AND m.valor_total > 0
          AND m.fecha IS NOT NULL AND m.fecha > v_hasta - interval '1 year'
    ),
    compras_delta AS (
        SELECT producto_id, proveedor, fecha, cantidad, precio,
               lag(precio) OVER (PARTITION BY producto_id, proveedor ORDER BY fecha) AS previo
        FROM compras_serie WHERE proveedor IS NOT NULL
    ),
    sube AS (
        SELECT producto_id, proveedor,
               -- El 1% de margen evita contar como "subida" el redondeo de un
               -- precio que en realidad no se movió.
               count(*) FILTER (WHERE previo IS NOT NULL AND precio > previo * 1.01) AS subidas,
               (array_agg(precio ORDER BY fecha))[1]      AS precio_ini,
               (array_agg(precio ORDER BY fecha DESC))[1] AS precio_fin,
               sum(cantidad) AS unidades
        FROM compras_delta
        GROUP BY 1, 2
    ),
    r_prov_sube AS (
        -- Un producto puede tener varios proveedores subiendo; se reporta el
        -- que más plata cuesta, igual que el resto de las reglas reportan lo
        -- peor de cada frente y no una lista.
        SELECT DISTINCT ON (s.producto_id)
               'proveedor_sube' AS regla, ('producto:' || s.producto_id) AS clave_objeto,
               '📈' AS icono, p.nombre_canonico AS titulo,
               round((s.precio_fin - s.precio_ini) * s.unidades / least(v_meses, 12)) AS impacto_mes,
               'mensual'::text AS impacto_tipo,
               format('Al ritmo que lo comprás son unos $%s más al mes que hace un año.',
                      miles(round((s.precio_fin - s.precio_ini) * s.unidades / least(v_meses, 12)))) AS impacto_txt,
               format('%s te subió el precio %s veces en el último año: de $%s a $%s.',
                      s.proveedor, s.subidas, miles(round(s.precio_ini)), miles(round(s.precio_fin))) AS problema,
               jsonb_build_array(
                 format('Preguntale a %s por qué, con los precios anteriores en la mano.', s.proveedor),
                 'Pedile precio a otro para este producto: no para cambiarte, para tener con qué negociar.') AS opciones,
               NULL::text AS origen_stock,
               jsonb_build_object('proveedor', s.proveedor) AS datos
        FROM sube s
        JOIN productos p ON p.id = s.producto_id
        WHERE s.subidas >= v_subidas AND s.precio_fin > s.precio_ini
        ORDER BY s.producto_id, (s.precio_fin - s.precio_ini) * s.unidades DESC
    ),

    -- R9. El margen se viene cayendo ---------------------------------------
    -- La única de las cuatro que necesita snapshots (B1). Se piden los dos
    -- últimos COMPLETOS: los parciales del backfill no traen el margen por
    -- producto, y compararse contra un hueco no es compararse.
    snaps AS (
        SELECT metricas, row_number() OVER (ORDER BY fecha DESC) AS n
        FROM snapshots_negocio
        WHERE negocio_id = p_negocio_id
          AND coalesce((metricas -> 'parcial')::boolean, false) = false
        ORDER BY fecha DESC LIMIT 2
    ),
    margen_hist AS (
        SELECT s.n, e.producto_id, e.margen_pct
        FROM snaps s,
             LATERAL jsonb_to_recordset(s.metricas -> 'margenes')
               AS e(producto_id bigint, margen_pct numeric)
    ),
    r_margen_cae AS (
        SELECT 'margen_cae' AS regla, ('producto:' || mp.producto_id) AS clave_objeto,
               '📉' AS icono, mp.nombre_canonico AS titulo,
               round((h2.margen_pct - mp.margen_pct) / 100.0
                     * coalesce(v.importe, 0) / v_meses) AS impacto_mes,
               'mensual'::text AS impacto_tipo,
               CASE WHEN coalesce(v.importe, 0) > 0
                    THEN format('Son unos $%s al mes que antes te quedaban y ahora no.',
                                miles(round((h2.margen_pct - mp.margen_pct) / 100.0
                                            * v.importe / v_meses)))
                    ELSE '' END AS impacto_txt,
               format('Tu margen viene bajando dos periodos seguidos: %s%%, después %s%%, y ahora %s%%.',
                      fmt_decimal(h2.margen_pct), fmt_decimal(h1.margen_pct),
                      fmt_decimal(mp.margen_pct)) AS problema,
               jsonb_build_array(
                 'No es un mal mes: es una tendencia. Mirá si subió el costo o si bajaste el precio sin darte cuenta.',
                 format('Para volver al %s%% de antes, el precio tendría que ser $%s.',
                        fmt_decimal(h2.margen_pct),
                        miles(round(mp.costo_actual / nullif(1 - h2.margen_pct/100, 0))))) AS opciones,
               NULL::text AS origen_stock,
               jsonb_build_object('precio_sugerido',
                 round(mp.costo_actual / nullif(1 - h2.margen_pct/100, 0))) AS datos
        FROM v_margen_producto mp
        JOIN margen_hist h1 ON h1.n = 1 AND h1.producto_id = mp.producto_id
        JOIN margen_hist h2 ON h2.n = 2 AND h2.producto_id = mp.producto_id
        LEFT JOIN venta_hist v ON v.producto_id = mp.producto_id
        WHERE mp.negocio_id = p_negocio_id
          AND mp.margen_pct IS NOT NULL AND mp.costo_actual IS NOT NULL
          AND h1.margen_pct IS NOT NULL AND h2.margen_pct IS NOT NULL
          -- Dos caídas seguidas, no una. Un solo mes malo es ruido.
          AND mp.margen_pct < h1.margen_pct
          AND h1.margen_pct  < h2.margen_pct
          AND (h2.margen_pct - mp.margen_pct) >= v_caida_margen
    ),

    -- R10. Vendés menos que el año pasado ----------------------------------
    -- La comparación que un tendero hace de memoria y casi siempre mal. Necesita
    -- trece meses de historia visible: por eso A1 tenía que ir primero — con el
    -- plan free borrando el pasado, esta regla no podía existir.
    anual AS (
        SELECT
          coalesce(sum(valor_total) FILTER (
            WHERE fecha >= v_mes_ref AND fecha < v_mes_ref + interval '1 month'), 0) AS ahora,
          coalesce(sum(valor_total) FILTER (
            WHERE fecha >= v_mes_ref - interval '1 year'
              AND fecha <  v_mes_ref - interval '1 year' + interval '1 month'), 0) AS antes
        FROM mov_visibles
        WHERE negocio_id = p_negocio_id AND tipo = 'venta' AND fecha IS NOT NULL
    ),
    r_vs_ano AS (
        SELECT 'vs_ano_anterior' AS regla, 'negocio'::text AS clave_objeto,
               '📅' AS icono, 'Vendés menos que el año pasado' AS titulo,
               round(a.antes - a.ahora) AS impacto_mes,
               'mensual'::text AS impacto_tipo,
               format('Son $%s menos que en el mismo mes del año pasado.',
                      miles(round(a.antes - a.ahora))) AS impacto_txt,
               format('En %s vendiste $%s. El mismo mes del año pasado habías vendido $%s: %s%% menos.',
                      mes_es(v_mes_ref), miles(round(a.ahora)), miles(round(a.antes)),
                      fmt_decimal(round((a.antes - a.ahora) * 100.0 / nullif(a.antes, 0), 1))) AS problema,
               jsonb_build_array(
                 'Mirá qué productos se vendían entonces y ahora no: ahí suele estar la respuesta.',
                 'Si el año pasado tuviste algo puntual —una temporada, un cliente grande— no es comparable y podés ignorarlo.') AS opciones,
               NULL::text AS origen_stock,
               '{}'::jsonb AS datos
        FROM anual a
        WHERE a.antes > 0
          AND (a.antes - a.ahora) * 100.0 / a.antes >= v_caida_anual
    ),

    -- R11. Te deben y ya se pasaron de la fecha -----------------------------
    -- La cartera existía desde la 036 como pieza de ERP: datos que se cargaban
    -- y se miraban en una pestaña. Acá pasa a ser lo que justifica su
    -- existencia dentro de este producto — una señal de LIQUIDEZ, con impacto
    -- de tipo `capital`: no es plata que se pierde, es plata que es tuya y no
    -- está. Exactamente el mismo caso que "plata quieta", y por eso comparte
    -- umbral y tratamiento.
    -- El impacto es el saldo VENCIDO, no el total que ese cliente debe. No es un
    -- detalle: un cliente que debe $10.000.000 con $100.000 en mora tendría un
    -- impacto cien veces mayor del real y encabezaría el informe por encima de
    -- problemas que sí cuestan plata. `v_cartera_tercero` no separa las dos
    -- cosas, así que la cuenta se hace acá.
    cartera_mora AS (
        SELECT f.tercero_id, t.nombre,
               sum(f.saldo) AS saldo_total,
               sum(f.saldo) FILTER (
                 WHERE f.vencimiento IS NOT NULL
                   AND f.vencimiento < current_date)        AS saldo_vencido,
               count(*) FILTER (
                 WHERE f.vencimiento IS NOT NULL
                   AND f.vencimiento < current_date)        AS facturas_vencidas,
               max(current_date - f.vencimiento) FILTER (
                 WHERE f.vencimiento < current_date)        AS dias_mora
        FROM facturas f
        JOIN terceros t ON t.id = f.tercero_id
        WHERE f.negocio_id = p_negocio_id
          AND f.tipo = 'venta'          -- lo que te deben, no lo que debés
          AND f.saldo > 0
        GROUP BY 1, 2
    ),
    r_cartera AS (
        SELECT 'cartera' AS regla, ('tercero:' || c.tercero_id) AS clave_objeto,
               '💵' AS icono, c.nombre AS titulo,
               round(c.saldo_vencido) AS impacto_mes,
               'capital'::text AS impacto_tipo,
               format('Son $%s tuyos que ya se pasaron de fecha.',
                      miles(round(c.saldo_vencido))) AS impacto_txt,
               format('%s te debe $%s vencidos en %s factura%s, y la más vieja lleva %s días.',
                      c.nombre, miles(round(c.saldo_vencido)), c.facturas_vencidas,
                      CASE WHEN c.facturas_vencidas = 1 THEN '' ELSE 's' END,
                      c.dias_mora)
               -- Si además hay saldo por vencer se dice, pero aparte: mezclarlo
               -- con lo vencido es lo que infla la cifra.
               || CASE WHEN c.saldo_total > c.saldo_vencido
                       THEN format(' Te debe otros $%s que todavía no se vencen.',
                                   miles(round(c.saldo_total - c.saldo_vencido)))
                       ELSE '' END AS problema,
               jsonb_build_array(
                 format('Llamá a %s esta semana: cuanto más vieja la factura, más cuesta cobrarla.', c.nombre),
                 'Si ya te pagó, registralo en el portal para que deje de aparecer acá.') AS opciones,
               NULL::text AS origen_stock,
               jsonb_build_object('tercero_id', c.tercero_id,
                                  'saldo_vencido', round(c.saldo_vencido),
                                  'saldo_total', round(c.saldo_total),
                                  'dias_mora', c.dias_mora) AS datos
        FROM cartera_mora c
        WHERE c.dias_mora IS NOT NULL
          AND c.dias_mora >= v_mora_dias
          AND c.saldo_vencido > 0
    ),

    todas AS (
        SELECT * FROM r_costo        UNION ALL
        SELECT * FROM r_proveedor    UNION ALL
        SELECT * FROM r_margen       UNION ALL
        SELECT * FROM r_agota        UNION ALL
        SELECT * FROM r_quieto       UNION ALL
        SELECT * FROM r_dependencia  UNION ALL
        -- >>> 060: las comparativas.
        SELECT * FROM r_sin_ventas   UNION ALL
        SELECT * FROM r_prov_sube    UNION ALL
        SELECT * FROM r_margen_cae   UNION ALL
        SELECT * FROM r_vs_ano      UNION ALL
        -- >>> 069: la cartera como señal de liquidez.
        SELECT * FROM r_cartera
    ),
    -- La prioridad sigue siendo el impacto medido contra lo que mueve el
    -- negocio, pero cada tipo tiene su vara (055). La dependencia de proveedor
    -- no tiene impacto calculable y entra fija en media: es un riesgo, no una
    -- pérdida que ya esté ocurriendo.
    --
    -- `relevancia` = cuántas veces la recomendación supera el umbral MEDIA de su
    -- propio tipo. Es lo único comparable entre tipos, y es lo que ordena dentro
    -- de una misma prioridad. Antes ordenaba `impacto_mes` crudo, y un capital
    -- acumulado le ganaba siempre a una fuga mensual por ser un número mayor,
    -- aunque significara menos.
    priorizadas AS (
        SELECT t.regla, t.clave_objeto, t.datos,
               t.icono, t.titulo, t.problema, t.opciones, t.impacto_txt,
               t.origen_stock, t.impacto_tipo,
               coalesce(t.impacto_mes, 0) AS impacto_mes,
               CASE WHEN t.regla = 'dependencia' THEN 'media'
                    WHEN u.pct >= u.alta  THEN 'alta'
                    WHEN u.pct >= u.media THEN 'media'
                    ELSE 'baja' END AS prioridad,
               CASE WHEN t.regla = 'dependencia' THEN 0
                    ELSE u.pct / greatest(u.media, 0.0001) END AS relevancia,
               -- El tope por regla: lo peor de cada frente, no el ranking de
               -- pesos, que se llena con la regla que más productos toca.
               -- Dentro de una regla el tipo es el mismo, así que acá el monto
               -- crudo sí compara bien.
               row_number() OVER (PARTITION BY t.regla
                                  ORDER BY coalesce(t.impacto_mes, 0) DESC) AS rn
        FROM todas t
        CROSS JOIN LATERAL (
            SELECT coalesce(t.impacto_mes, 0) * 100.0 / v_base_mes AS pct,
                   CASE t.impacto_tipo WHEN 'unico'   THEN v_pri_alta_u
                                       WHEN 'capital' THEN v_pri_alta_k
                                       ELSE v_pri_alta END          AS alta,
                   CASE t.impacto_tipo WHEN 'unico'   THEN v_pri_media_u
                                       WHEN 'capital' THEN v_pri_media_k
                                       ELSE v_pri_media END         AS media
        ) u
        WHERE coalesce(t.titulo, '') <> ''
    ),
    -- >>> 059. Hasta acá el tope (2 por regla, 8 en total) se aplicaba en la
    -- consulta final y lo que quedaba afuera se perdía. Para persistir hace
    -- falta distinguir dos conjuntos que antes eran uno:
    --
    --   lo DETECTADO — todos los problemas que las reglas encontraron.
    --   lo MOSTRADO  — los que entraron al informe después de los topes.
    --
    -- Sin esa distinción, una recomendación abierta que hoy no aparece podría
    -- estar ausente porque el problema se arregló O porque la empujaron fuera
    -- del top 8, y cerrarla como "resuelta" en el segundo caso sería mentir.
    visibles AS (
        SELECT regla, clave_objeto,
               row_number() OVER (
                 ORDER BY CASE prioridad WHEN 'alta' THEN 1 WHEN 'media' THEN 2 ELSE 3 END,
                          relevancia DESC) AS pos
        FROM priorizadas WHERE rn <= 2
    ),
    salida AS (
        SELECT p.*, coalesce(v.pos <= 8, false) AS en_informe
        FROM priorizadas p
        LEFT JOIN visibles v
               ON v.regla = p.regla AND v.clave_objeto = p.clave_objeto
        -- En modo informe sale lo de siempre; en modo registro, todo.
        WHERE p_registro OR coalesce(v.pos, 2147483647) <= 8
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'icono', icono, 'prioridad', prioridad, 'titulo', titulo,
             'problema', problema,
             'impacto', coalesce(impacto_txt, ''),
             'impacto_mes', impacto_mes,
             -- >>> 055: qué clase de impacto es el número de arriba.
             --   mensual — pesos por mes que se van a seguir yendo
             --   unico   — pesos una sola vez, si el evento ocurre
             --   capital — pesos que existen y están inmóviles
             'impacto_tipo', impacto_tipo,
             'opciones', opciones,
             -- >>> 054: de dónde sale el stock con el que se calculó
             -- esto. 'estimado' = comprado menos vendido, sin conteo.
             'origen_stock', origen_stock)
             -- >>> 059: la identidad de la recomendación viaja SOLO en modo
             -- registro. En modo informe el JSON queda como estaba, que es lo
             -- que ve el modelo y lo que audita validar_cifras: no tiene por
             -- qué enterarse de una clave interna como 'producto:9'.
             || CASE WHEN p_registro
                     THEN jsonb_build_object('regla', regla,
                                             'clave_objeto', clave_objeto,
                                             'datos', coalesce(datos, '{}'::jsonb),
                                             'en_informe', en_informe)
                     ELSE '{}'::jsonb END
             ORDER BY CASE prioridad WHEN 'alta' THEN 1 WHEN 'media' THEN 2 ELSE 3 END,
                      relevancia DESC), '[]'::jsonb)
      INTO v_out
    FROM salida s;

    RETURN v_out;
END;
$_$;



CREATE FUNCTION public.recomendaciones_registrar(p_negocio_id bigint, p_ejecucion_id bigint DEFAULT NULL::bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_detectadas jsonb;
    v_nuevas     int := 0;
    v_seguian    int := 0;
    v_resueltas  int := 0;
    v_caducadas  int := 0;
    v_vistas     int := 0;
BEGIN
    v_detectadas := recomendaciones_negocio(p_negocio_id, true);


    -- ---- 1. Las que siguen -------------------------------------------------
    -- Se refrescan las cifras: el impacto cambia entre periodos y lo que
    -- interesa mostrar es el de hoy. `detectada_en` NO se toca — es cuándo
    -- empezó el problema, y es media respuesta a "¿desde cuándo vengo así?".
    WITH upd AS (
        UPDATE recomendaciones r
           SET titulo = d.titulo, problema = d.problema, impacto = d.impacto,
               impacto_mes = d.impacto_mes, impacto_tipo = d.impacto_tipo,
               prioridad = d.prioridad, opciones = coalesce(d.opciones, '[]'::jsonb),
               origen_stock = d.origen_stock, icono = d.icono,
               datos = coalesce(d.datos, '{}'::jsonb), revisada_en = now()
          FROM (SELECT * FROM jsonb_to_recordset(v_detectadas) AS e(
                  regla text, clave_objeto text, titulo text, problema text,
                  impacto text, impacto_mes numeric, impacto_tipo text,
                  prioridad text, opciones jsonb, origen_stock text,
                  datos jsonb, icono text, en_informe boolean)) d
         WHERE r.negocio_id = p_negocio_id AND r.regla = d.regla
           AND r.clave_objeto = d.clave_objeto
           AND r.estado IN ('nueva','vigente')
        RETURNING 1)
    SELECT count(*) INTO v_seguian FROM upd;

    -- ---- 2. Las que aparecen por primera vez -------------------------------
    WITH ins AS (
        INSERT INTO recomendaciones (negocio_id, regla, clave_objeto, titulo,
                 problema, impacto, impacto_mes, impacto_tipo, prioridad,
                 opciones, origen_stock, datos, icono, ejecucion_id)
        SELECT p_negocio_id, d.regla, d.clave_objeto, d.titulo, d.problema,
               d.impacto, d.impacto_mes, d.impacto_tipo, d.prioridad,
               coalesce(d.opciones, '[]'::jsonb), d.origen_stock,
               coalesce(d.datos, '{}'::jsonb), d.icono, p_ejecucion_id
        FROM (SELECT * FROM jsonb_to_recordset(v_detectadas) AS e(
                  regla text, clave_objeto text, titulo text, problema text,
                  impacto text, impacto_mes numeric, impacto_tipo text,
                  prioridad text, opciones jsonb, origen_stock text,
                  datos jsonb, icono text, en_informe boolean)) d
        WHERE NOT EXISTS (
            SELECT 1 FROM recomendaciones r
             WHERE r.negocio_id = p_negocio_id AND r.regla = d.regla
               AND r.clave_objeto = d.clave_objeto
               AND r.estado IN ('nueva','vigente'))
        RETURNING 1)
    SELECT count(*) INTO v_nuevas FROM ins;

    -- ---- 3. Las que ya no están --------------------------------------------
    -- >>> 066: la foto de la magnitud ANTES de cerrarlas. Después de cerrar el
    -- valor sigue siendo el mismo, pero el orden explícito evita que un
    -- reordenamiento futuro rompa la medición sin que nadie se entere.
    PERFORM recomendacion_marcar_cierre(re.id)
    FROM recomendaciones re
    WHERE re.negocio_id = p_negocio_id
      AND re.estado IN ('nueva','vigente')
      AND NOT EXISTS (SELECT 1 FROM jsonb_to_recordset(v_detectadas)
                               AS d(regla text, clave_objeto text)
                       WHERE d.regla = re.regla AND d.clave_objeto = re.clave_objeto);

    WITH cerradas AS (
        UPDATE recomendaciones r
           SET estado      = CASE WHEN recomendacion_objeto_evaluable(p_negocio_id, r.clave_objeto)
                                  THEN 'resuelta' ELSE 'caducada' END,
               cerrada_por = CASE WHEN recomendacion_objeto_evaluable(p_negocio_id, r.clave_objeto)
                                  THEN 'dato' ELSE 'sin_datos' END,
               cerrada_en  = now(), revisada_en = now()
         WHERE r.negocio_id = p_negocio_id
           AND r.estado IN ('nueva','vigente')
           -- Basta con esto: el paso 1 solo tocó las que SÍ están detectadas,
           -- así que no hay forma de que una de ellas caiga acá.
           AND NOT EXISTS (SELECT 1 FROM jsonb_to_recordset(v_detectadas)
                                    AS d(regla text, clave_objeto text)
                            WHERE d.regla = r.regla AND d.clave_objeto = r.clave_objeto)
        RETURNING estado)
    SELECT count(*) FILTER (WHERE estado = 'resuelta'),
           count(*) FILTER (WHERE estado = 'caducada')
      INTO v_resueltas, v_caducadas
    FROM cerradas;

    -- ---- 4. Lo que llegó al informe cuenta como visto ----------------------
    -- Solo lo que entró al top 8. Marcar como vista una recomendación que el
    -- dueño nunca leyó dejaría el dato inservible el día que D1 le pregunte
    -- "¿hiciste algo con esto?".
    WITH marcadas AS (
        UPDATE recomendaciones r
           SET estado = 'vigente',
               vista_en = coalesce(r.vista_en, now()),
               veces_vista = r.veces_vista + 1
          FROM (SELECT * FROM jsonb_to_recordset(v_detectadas)
                         AS e(regla text, clave_objeto text, en_informe boolean)) d
         WHERE r.negocio_id = p_negocio_id AND r.regla = d.regla
           AND r.clave_objeto = d.clave_objeto
           AND d.en_informe
           AND r.estado IN ('nueva','vigente')
        RETURNING 1)
    SELECT count(*) INTO v_vistas FROM marcadas;

    RETURN jsonb_build_object('nuevas', v_nuevas, 'seguian', v_seguian,
                              'resueltas', v_resueltas, 'caducadas', v_caducadas,
                              'mostradas', v_vistas);
END;
$$;



CREATE FUNCTION public.recomendaciones_vigentes(p_negocio_id bigint, p_limite integer DEFAULT 20) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'id', id, 'regla', regla, 'clave_objeto', clave_objeto,
             'icono', icono,
             'titulo', titulo, 'problema', problema, 'impacto', impacto,
             'impacto_mes', impacto_mes, 'impacto_tipo', impacto_tipo,
             'prioridad', prioridad, 'opciones', opciones,
             'datos', coalesce(datos, '{}'::jsonb),
             'origen_stock', origen_stock, 'estado', estado,
             'detectada_en', detectada_en, 'veces_vista', veces_vista,
             -- Cuántos periodos lleva sin resolverse. Es la diferencia entre
             -- "te lo digo por primera vez" y "van cuatro veces".
             'dias_abierta', (current_date - detectada_en::date))
             ORDER BY CASE prioridad WHEN 'alta' THEN 1 WHEN 'media' THEN 2 ELSE 3 END,
                      impacto_mes DESC), '[]'::jsonb)
    FROM (SELECT * FROM recomendaciones
           WHERE negocio_id = p_negocio_id AND estado IN ('nueva','vigente')
           ORDER BY CASE prioridad WHEN 'alta' THEN 1 WHEN 'media' THEN 2 ELSE 3 END,
                    impacto_mes DESC
           LIMIT p_limite) r;
$$;



CREATE FUNCTION public.resolver_plantilla(p_clave text, p_vars jsonb DEFAULT '{}'::jsonb, p_teclado jsonb DEFAULT NULL::jsonb) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $$
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



CREATE FUNCTION public.router_arranque_servicio(p_negocio_id bigint, p_chat_id bigint, p_servicio text) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
             jsonb_build_object('servicio', v_nombre,
                                'formatos', extensiones_aceptadas()));
END;
$$;



CREATE FUNCTION public.router_ctx(p_evento jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $_$
DECLARE
    v_usuario_id bigint;
    v_texto      text := btrim(coalesce(p_evento ->> 'texto', ''));
    v_cmd        text;
    v_arg        text;          -- resto del mensaje después del comando
    v_svc        text;          -- código que llegó por botón (svc:<codigo>)
    v_mod        text;          -- código de módulo (mod:/modayuda:)
    v_tip        text;          -- >>> 046: naturaleza del negocio (tipo:<codigo>)
    v_rec        text;          -- >>> 064: acción sobre una recomendación
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
    ELSIF v_texto LIKE 'rec:%' THEN
        -- >>> 064: 'rec:<accion>[:<id>]'. El resto queda entero en `rec` y lo
        -- parte el handler: acá solo se reconoce el prefijo.
        v_rec := substring(v_texto FROM 5);
        v_cmd := 'rec';
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
        'rec',        v_rec,
        'tiene_doc',  coalesce((p_evento ->> 'tiene_documento')::boolean, false),
        'n_serv',     v_n_serv,
        'consulta',   v_consulta);
END;
$_$;



CREATE FUNCTION public.router_h_admin(p_ctx jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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



CREATE FUNCTION public.router_h_comandos(p_ctx jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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
    v_rec        text    := p_ctx ->> 'rec';   -- >>> 064
    v_rec_acc    text;
    v_rec_id     bigint;
    v_reco       record;
    v_res        jsonb;
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

    -- ---- >>> 064: acciones sobre una recomendación -------------------------
    -- Va DESPUÉS del consentimiento a propósito: acá se muestran cifras del
    -- negocio, así que exige autorización como todo lo que entrega datos.
    IF v_cmd = 'rec' THEN
        v_rec_acc := split_part(v_rec, ':', 1);
        v_rec_id  := nullif(split_part(v_rec, ':', 2), '')::bigint;

        IF v_negocio_id IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
        END IF;

        IF v_rec_acc = 'list' THEN
            IF NOT EXISTS (SELECT 1 FROM recomendaciones
                            WHERE negocio_id = v_negocio_id
                              AND estado IN ('nueva','vigente')) THEN
                RETURN router_respuesta(v_chat_id, 'recomendacion.sin_pendientes');
            END IF;
            RETURN router_respuesta(v_chat_id, 'recomendacion.lista', '{}'::jsonb,
                     teclado_recomendaciones(v_negocio_id));
        END IF;

        IF v_rec_id IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
        END IF;

        IF v_rec_acc = 'ver' THEN
            SELECT * INTO v_reco FROM recomendaciones
            WHERE id = v_rec_id AND negocio_id = v_negocio_id
              AND estado IN ('nueva','vigente');
            IF v_reco.id IS NULL THEN
                RETURN router_respuesta(v_chat_id, 'recomendacion.no_encontrada');
            END IF;
            RETURN router_respuesta(v_chat_id, 'recomendacion.detalle',
                     jsonb_build_object(
                       'icono', coalesce(v_reco.icono, '🔎'),
                       'titulo', v_reco.titulo,
                       'problema', coalesce(v_reco.problema, ''),
                       'impacto', coalesce(v_reco.impacto, ''),
                       'dias', (current_date - v_reco.detectada_en::date)),
                     teclado_recomendacion(v_rec_id));
        END IF;

        IF v_rec_acc IN ('hice','no_aplica','precio') THEN
            v_res := recomendacion_accion(v_rec_id, v_negocio_id, v_rec_acc,
                                          v_usuario_id);
            IF coalesce((v_res ->> 'ok')::boolean, false) = false THEN
                RETURN router_respuesta(v_chat_id,
                         CASE v_res ->> 'error' WHEN 'sin_precio'
                              THEN 'recomendacion.sin_precio'
                              ELSE 'recomendacion.no_encontrada' END);
            END IF;
            RETURN router_respuesta(v_chat_id,
                     CASE v_rec_acc WHEN 'hice'   THEN 'recomendacion.hecha'
                                    WHEN 'precio' THEN 'recomendacion.precio_aplicado'
                                    ELSE 'recomendacion.ignorada' END,
                     jsonb_build_object('titulo', v_res ->> 'titulo',
                                        'precio', coalesce(v_res ->> 'precio', '')),
                     teclado_recomendaciones(v_negocio_id));
        END IF;

        RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
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



CREATE FUNCTION public.router_h_intake(p_ctx jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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



CREATE FUNCTION public.router_h_recibiendo(p_ctx jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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



CREATE FUNCTION public.router_h_sin_sesion(p_ctx jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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



CREATE FUNCTION public.router_marcar_editables(p_res jsonb, p_evento jsonb) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
    SELECT CASE
      -- Sin mensaje que editar (llegó escrito, o es WhatsApp) no hay nada que
      -- hacer. Es el camino de siempre y tiene que salir intacto.
      WHEN nullif(p_evento ->> 'message_id', '') IS NULL
        OR jsonb_array_length(coalesce(p_res -> 'respuestas', '[]'::jsonb)) = 0
      THEN p_res
      ELSE jsonb_set(p_res, '{respuestas}', (
        SELECT jsonb_agg(
                 CASE WHEN coalesce(pl.reemplaza, false)
                      THEN e.r || jsonb_build_object('editar',
                             (p_evento ->> 'message_id')::bigint)
                      ELSE e.r END
                 ORDER BY e.ord)
        FROM jsonb_array_elements(p_res -> 'respuestas')
             WITH ORDINALITY AS e(r, ord)
        LEFT JOIN plantillas pl ON pl.clave = e.r ->> 'plantilla'))
    END;
$$;



CREATE FUNCTION public.router_plan(p_negocio_id bigint, p_chat_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_plan   text;
    c        record;
    v_pct    numeric := 0;
    v_enlace text;
    v_aviso_cupo text := '';
    v_aviso_pago text := '';
BEGIN
    -- Sin negocio asignado no hay plan que mostrar.
    IF p_negocio_id IS NULL THEN
        RETURN router_respuesta(p_chat_id, 'sistema.no_entendido');
    END IF;

    SELECT plan INTO v_plan FROM negocios WHERE id = p_negocio_id;
    SELECT * INTO c FROM v_consumo_negocio WHERE negocio_id = p_negocio_id;

    IF c.cupo_tokens_mes > 0 THEN
        v_pct := round(100.0 * c.tokens_mes / c.cupo_tokens_mes);
    END IF;

    -- cupo 0 = bloqueado (regla de la 001); pasado el 80% se avisa antes de
    -- que ejecucion_preparar empiece a bloquear.
    IF c.cupo_tokens_mes = 0 THEN
        v_aviso_cupo := E'\n\n⛔ El servicio está suspendido para tu negocio.';
    ELSIF v_pct >= 100 THEN
        v_aviso_cupo := E'\n\n⛔ Superaste el cupo del mes: los análisis quedan bloqueados hasta el próximo mes o hasta ampliar el plan.';
    ELSIF v_pct >= 80 THEN
        v_aviso_cupo := E'\n\n⚠️ Vas por el ' || v_pct || '% del cupo del mes.';
    END IF;

    v_enlace := btrim(coalesce(parametro(p_negocio_id, 'pago_enlace') #>> '{}', ''));
    IF v_enlace <> '' THEN
        v_aviso_pago := E'\n\n💳 <a href="' || v_enlace ||
                        '">Pagar o ampliar el plan</a> (te lleva a Wompi, pago seguro).';
    END IF;

    RETURN router_respuesta(p_chat_id, 'plan.estado', jsonb_build_object(
        'plan', coalesce(v_plan, 'free'),
        'ejecuciones', coalesce(c.ejecuciones_mes, 0),
        'tokens', miles(coalesce(c.tokens_mes, 0)),
        'cupo', miles(coalesce(c.cupo_tokens_mes, 0)),
        'pct', v_pct,
        'aviso_cupo', v_aviso_cupo,
        'aviso_pago', v_aviso_pago));
END;
$$;



CREATE FUNCTION public.router_portal(p_usuario_id bigint, p_chat_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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



CREATE FUNCTION public.router_procesar_mensaje(p_evento jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
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



CREATE FUNCTION public.router_respuesta(p_chat bigint, p_plantilla text, p_vars jsonb DEFAULT '{}'::jsonb, p_teclado jsonb DEFAULT NULL::jsonb, p_acciones jsonb DEFAULT '[]'::jsonb) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT jsonb_build_object(
      'chat_id', p_chat,
      'respuestas', CASE WHEN p_plantilla IS NULL THEN '[]'::jsonb
                    ELSE jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                           'plantilla', p_plantilla,
                           'vars', coalesce(p_vars, '{}'::jsonb),
                           'teclado', p_teclado))) END,
      'acciones', coalesce(p_acciones, '[]'::jsonb));
$$;



CREATE FUNCTION public.salud_negocio(p_negocio_id bigint) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_margen_min numeric := coalesce((parametro(p_negocio_id,'margen_minimo_pct'))::text::numeric, 20);
    v_dias_cob   numeric := coalesce((parametro(p_negocio_id,'dias_cobertura_min'))::text::numeric, 7);
    v_lenta      numeric := coalesce((parametro(p_negocio_id,'rotacion_lenta_dias'))::text::numeric, 60);
    v_deriva_ali numeric := coalesce((parametro(p_negocio_id,'deriva_costo_alerta_pct'))::text::numeric, 8);
    v_ventas     numeric;
    v_margenes   numeric;
    v_inventario numeric;
    v_compras    numeric;
    v_riesgos    numeric;
    v_liquidez   numeric;
    v_indice     numeric;
    v_mitad      date;
    v_desde      date;
    v_hasta      date;
    v_inv_est    boolean;
BEGIN
    SELECT min(fecha), max(fecha) INTO v_desde, v_hasta
    FROM mov_visibles WHERE negocio_id = p_negocio_id AND fecha IS NOT NULL;

    -- --- Ventas: ¿la segunda mitad del periodo vendió más que la primera? ----
    IF v_desde IS NOT NULL AND v_hasta - v_desde >= 14 THEN
        v_mitad := v_desde + ((v_hasta - v_desde) / 2);
        SELECT CASE WHEN coalesce(sum(valor_total) FILTER (WHERE fecha <= v_mitad), 0) > 0
                    THEN least(100, greatest(0, round(50 +
                          (coalesce(sum(valor_total) FILTER (WHERE fecha > v_mitad), 0)
                           - sum(valor_total) FILTER (WHERE fecha <= v_mitad))
                          * 100.0 / sum(valor_total) FILTER (WHERE fecha <= v_mitad))))
               END
          INTO v_ventas
        FROM mov_visibles
        WHERE negocio_id = p_negocio_id AND tipo = 'venta' AND fecha IS NOT NULL;
    END IF;

    -- --- Márgenes: qué porcentaje de los productos con precio llega al mínimo -
    SELECT CASE WHEN count(*) > 0
                THEN round(count(*) FILTER (WHERE margen_pct >= v_margen_min) * 100.0 / count(*))
           END
      INTO v_margenes
    FROM v_margen_producto
    WHERE negocio_id = p_negocio_id AND precio_actual IS NOT NULL AND margen_pct IS NOT NULL;

    -- --- Inventario: qué porcentaje está en cobertura sana -------------------
    SELECT CASE WHEN count(*) > 0
                THEN round(count(*) FILTER (WHERE dias_cobertura BETWEEN v_dias_cob AND v_lenta)
                           * 100.0 / count(*))
           END
      INTO v_inventario
    FROM v_rotacion_producto
    WHERE negocio_id = p_negocio_id AND dias_cobertura IS NOT NULL;

    -- --- Compras: cuántos productos NO tienen el costo disparado ------------
    SELECT CASE WHEN count(*) > 0
                THEN round(count(*) FILTER (WHERE deriva_pct < v_deriva_ali) * 100.0 / count(*))
           END
      INTO v_compras
    FROM v_deriva_costo WHERE negocio_id = p_negocio_id;

    -- --- Riesgos: concentración de compras en un solo proveedor -------------
    SELECT CASE WHEN sum(gasto) > 0
                THEN least(100, greatest(0,
                       round(100 - (max(gasto) * 100.0 / sum(gasto))
                                 + 20)))   -- un 40% de concentración ya es sano
           END
      INTO v_riesgos
    FROM (SELECT nullif(btrim(coalesce(raw ->> 'proveedor','')),'') AS prov,
                 sum(valor_total) AS gasto
          FROM mov_visibles
          WHERE negocio_id = p_negocio_id AND tipo = 'compra'
            AND nullif(btrim(coalesce(raw ->> 'proveedor','')),'') IS NOT NULL
          GROUP BY 1) t;

    -- --- >>> 069. Liquidez: qué parte de lo que te deben está al día --------
    -- NULL si el negocio no tiene una sola factura a crédito, igual que las
    -- otras cinco. Un negocio que vende todo de contado no tiene por qué ver
    -- bajar su índice por una nota que no le aplica.
    SELECT CASE WHEN sum(saldo) > 0
                THEN round(100 - (coalesce(sum(saldo) FILTER (
                       WHERE vencimiento IS NOT NULL AND vencimiento < current_date), 0)
                     * 100.0 / sum(saldo)))
           END
      INTO v_liquidez
    FROM facturas
    WHERE negocio_id = p_negocio_id AND tipo = 'venta' AND saldo > 0;

    -- >>> 054: ¿la nota de inventario se calculó sobre stock estimado?
    SELECT bool_or(origen_stock = 'estimado') INTO v_inv_est
    FROM v_rotacion_producto
    WHERE negocio_id = p_negocio_id AND dias_cobertura IS NOT NULL;

    SELECT round(avg(n)) INTO v_indice
    FROM unnest(ARRAY[v_ventas, v_margenes, v_inventario, v_compras,
                      v_riesgos, v_liquidez]) AS n
    WHERE n IS NOT NULL;

    IF v_indice IS NULL THEN
        RETURN NULL;   -- sin datos suficientes, no se dibuja el semáforo
    END IF;

    RETURN jsonb_strip_nulls(jsonb_build_object(
        'ventas', v_ventas, 'margenes', v_margenes, 'inventario', v_inventario,
        'compras', v_compras, 'riesgos', v_riesgos, 'liquidez', v_liquidez,
        'indice', v_indice,
        'inventario_estimado', CASE WHEN v_inventario IS NULL THEN NULL
                                    ELSE coalesce(v_inv_est, false) END));
END;
$$;



CREATE FUNCTION public.semaforo(p_valor numeric) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT CASE WHEN p_valor IS NULL THEN '⚪'
                WHEN p_valor >= 80 THEN '🟢'
                WHEN p_valor >= 65 THEN '🟡'
                WHEN p_valor >= 50 THEN '🟠'
                ELSE '🔴' END;
$$;



CREATE FUNCTION public.snapshot_anterior(p_negocio_id bigint, p_antes_de date DEFAULT CURRENT_DATE) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
    SELECT jsonb_build_object(
             'id', id, 'fecha', fecha, 'version', version,
             'periodo_desde', lower(periodo), 'periodo_hasta', upper(periodo),
             'origen', origen, 'salud', salud, 'metricas', metricas)
    FROM snapshots_negocio
    WHERE negocio_id = p_negocio_id AND fecha < p_antes_de
    ORDER BY fecha DESC
    LIMIT 1;
$$;



CREATE FUNCTION public.snapshot_tomar(p_negocio_id bigint, p_origen text DEFAULT 'manual'::text, p_ejecucion_id bigint DEFAULT NULL::bigint) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_desde    date;
    v_hasta    date;
    v_meses    numeric;
    v_metricas jsonb;
    v_id       bigint;
BEGIN
    SELECT min(fecha), max(fecha) INTO v_desde, v_hasta
    FROM mov_visibles WHERE negocio_id = p_negocio_id AND fecha IS NOT NULL;

    -- Sin un solo movimiento fechado no hay estado que fotografiar. Devolver
    -- NULL en vez de una fila vacía: un snapshot de la nada haría creer a B3
    -- que hubo un periodo medido en el que todo valía cero.
    IF v_desde IS NULL THEN
        RETURN NULL;
    END IF;

    -- La misma ventana con la que `recomendaciones_negocio` escala lo mensual.
    v_meses := greatest((v_hasta - v_desde)::numeric / 30.0, 1);

    SELECT jsonb_build_object(
      -- --- Totales del periodo ------------------------------------------------
      'totales', (SELECT jsonb_build_object(
                    'ventas',   round(coalesce(sum(valor_total) FILTER (WHERE tipo = 'venta'), 0)),
                    'compras',  round(coalesce(sum(valor_total) FILTER (WHERE tipo = 'compra'), 0)),
                    'movimientos_venta',  count(*) FILTER (WHERE tipo = 'venta'),
                    'movimientos_compra', count(*) FILTER (WHERE tipo = 'compra'),
                    'meses', round(v_meses, 2),
                    -- Lo que mueve el negocio en un mes: es el denominador con
                    -- el que se priorizan las recomendaciones, así que sin él un
                    -- impacto de dos snapshots distintos no es comparable.
                    'base_mes', round(greatest(
                        coalesce(sum(valor_total) FILTER (WHERE tipo = 'venta'),
                                 sum(valor_total) FILTER (WHERE tipo = 'compra'), 0) / v_meses, 1)))
                  FROM mov_visibles WHERE negocio_id = p_negocio_id),

      -- --- Resumen de catálogo ------------------------------------------------
      'productos', (SELECT jsonb_build_object(
                      'total', count(*),
                      'con_precio', count(*) FILTER (WHERE precio_actual IS NOT NULL),
                      'margen_promedio_pct', round(avg(margen_pct), 2))
                    FROM v_margen_producto WHERE negocio_id = p_negocio_id),

      -- --- Margen por producto (TODOS, no solo los que disparan regla) --------
      -- Guardar solo los de margen bajo sería guardar el informe otra vez. Para
      -- ver un deterioro hay que tener también los que hoy están bien.
      'margenes', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                     'producto_id', producto_id, 'nombre', nombre_canonico,
                     'costo', costo_actual, 'precio', precio_actual,
                     'margen_pct', margen_pct) ORDER BY producto_id), '[]'::jsonb)
                   FROM v_margen_producto WHERE negocio_id = p_negocio_id),

      -- --- Cobertura y stock por producto -------------------------------------
      'coberturas', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                       'producto_id', r.producto_id, 'nombre', p.nombre_canonico,
                       'dias_cobertura', r.dias_cobertura,
                       'unidades_por_dia', r.unidades_por_dia,
                       'balance', b.balance,
                       -- 054: sin esto, comparar dos coberturas puede ser
                       -- comparar un conteo real contra una estimación.
                       'origen_stock', r.origen_stock) ORDER BY r.producto_id), '[]'::jsonb)
                     FROM v_rotacion_producto r
                     JOIN productos p ON p.id = r.producto_id
                     LEFT JOIN v_balance_unidades b
                            ON b.producto_id = r.producto_id AND b.negocio_id = r.negocio_id
                     WHERE r.negocio_id = p_negocio_id),

      -- --- Deriva de costo ----------------------------------------------------
      'derivas', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                    'producto_id', producto_id, 'costo_ini', costo_ini,
                    'costo_fin', costo_fin, 'deriva_pct', deriva_pct)
                    ORDER BY producto_id), '[]'::jsonb)
                  FROM v_deriva_costo WHERE negocio_id = p_negocio_id),

      -- --- Gasto por proveedor ------------------------------------------------
      -- El % va calculado y no derivado al leer: si mañana entra una compra
      -- vieja, el gasto total del periodo cambia, y el snapshot tiene que
      -- seguir diciendo qué concentración se midió ESE día.
      'proveedores', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'proveedor', prov, 'gasto', round(gasto), 'pct', pct)
                        ORDER BY gasto DESC), '[]'::jsonb)
                      FROM (SELECT prov, gasto,
                                   round(gasto * 100.0 / nullif(sum(gasto) OVER (), 0), 1) AS pct
                            FROM (SELECT nullif(btrim(coalesce(raw ->> 'proveedor','')),'') AS prov,
                                         sum(valor_total) AS gasto
                                  FROM mov_visibles
                                  WHERE negocio_id = p_negocio_id AND tipo = 'compra'
                                    AND nullif(btrim(coalesce(raw ->> 'proveedor','')),'') IS NOT NULL
                                  GROUP BY 1) g0) g),

      -- --- Precio pagado por producto y proveedor -----------------------------
      -- Es lo que hace posible "este proveedor te subió tres veces en el año".
      -- Sin el par (producto, proveedor) solo se ve el gasto agregado, que sube
      -- también cuando simplemente comprás más.
      'precios_proveedor', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                              'producto_id', producto_id, 'proveedor', prov,
                              'precio_prom', round(precio_prom, 2), 'unidades', u)
                              ORDER BY producto_id, prov), '[]'::jsonb)
                            FROM (SELECT producto_id,
                                         nullif(btrim(coalesce(raw ->> 'proveedor','')),'') AS prov,
                                         sum(cantidad) AS u,
                                         sum(valor_total) / nullif(sum(cantidad), 0) AS precio_prom
                                  FROM mov_visibles
                                  WHERE negocio_id = p_negocio_id AND tipo = 'compra'
                                    AND producto_id IS NOT NULL AND cantidad > 0
                                    AND nullif(btrim(coalesce(raw ->> 'proveedor','')),'') IS NOT NULL
                                  GROUP BY 1, 2) pp),

      -- --- Unidades vendidas por producto -------------------------------------
      -- Para "este producto dejó de venderse", que se detecta comparando contra
      -- un snapshot anterior donde sí figuraba.
      'ventas_producto', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                            'producto_id', producto_id, 'unidades', round(u, 3),
                            'importe', round(imp)) ORDER BY producto_id), '[]'::jsonb)
                          FROM (SELECT producto_id, sum(cantidad) AS u, sum(valor_total) AS imp
                                FROM mov_visibles
                                WHERE negocio_id = p_negocio_id AND tipo = 'venta'
                                  AND producto_id IS NOT NULL
                                GROUP BY 1) vp),

      -- --- Concentración de utilidad ------------------------------------------
      'pareto', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                   'producto_id', producto_id, 'utilidad', round(utilidad),
                   'pct_utilidad', pct_utilidad, 'pct_acumulado', pct_acumulado)
                   ORDER BY utilidad DESC), '[]'::jsonb)
                 FROM v_pareto_utilidad WHERE negocio_id = p_negocio_id),

      -- --- Calidad del dato sobre el que se midió todo esto -------------------
      -- Un snapshot con el 40% de la plata sin producto resuelto (057) no es
      -- comparable con uno limpio, y quien compare tiene que poder saberlo.
      'calidad', (SELECT jsonb_build_object(
                    'movs_sin_producto', movs_sin_producto,
                    'dinero_sin_producto', dinero_sin_producto,
                    'pct_dinero_fuera', coalesce(pct_dinero_fuera, 0),
                    'productos_stock_estimado', (
                      SELECT count(*) FROM v_balance_unidades
                       WHERE negocio_id = p_negocio_id AND origen_stock = 'estimado'))
                  FROM v_calidad_matching WHERE negocio_id = p_negocio_id),

      -- --- Con qué umbrales se midió ------------------------------------------
      -- Los umbrales son por negocio y se pueden cambiar. Una nota de salud que
      -- baja porque alguien movió `margen_minimo_pct` no es un deterioro del
      -- negocio, y sin esto no habría forma de distinguirlo.
      'umbrales', snapshot_umbrales(p_negocio_id)
    ) INTO v_metricas;

    INSERT INTO snapshots_negocio (negocio_id, fecha, version, periodo, salud,
                                   metricas, origen, ejecucion_id)
    VALUES (p_negocio_id, current_date, snapshot_version(),
            daterange(v_desde, v_hasta, '[]'),
            salud_negocio(p_negocio_id), v_metricas, p_origen, p_ejecucion_id)
    ON CONFLICT ON CONSTRAINT uq_snapshot_dia DO UPDATE
      SET version = EXCLUDED.version, periodo = EXCLUDED.periodo,
          salud = EXCLUDED.salud, metricas = EXCLUDED.metricas,
          origen = EXCLUDED.origen, ejecucion_id = EXCLUDED.ejecucion_id,
          creado_en = now()
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;



CREATE FUNCTION public.snapshot_umbrales(p_negocio_id bigint) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
    SELECT coalesce(jsonb_object_agg(clave, valor), '{}'::jsonb)
    FROM (SELECT DISTINCT ON (clave) clave, valor
          FROM parametros
          WHERE negocio_id = p_negocio_id OR negocio_id IS NULL
          ORDER BY clave, negocio_id NULLS LAST) t;
$$;



CREATE FUNCTION public.snapshot_version() RETURNS integer
    LANGUAGE sql IMMUTABLE
    AS $$ SELECT 1 $$;



CREATE FUNCTION public.snapshots_backfill() RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_n int := 0;
    r   record;
BEGIN
    FOR r IN
        -- Una ejecución por negocio y día: la última completada de cada día.
        SELECT DISTINCT ON (e.negocio_id, e.inicio::date)
               e.id, e.negocio_id, e.inicio::date AS fecha, e.hallazgos AS h
        FROM ejecuciones e
        JOIN servicios s ON s.codigo = e.servicio_codigo AND s.entrada = 'archivos'
        WHERE e.estado = 'completada'
          AND jsonb_typeof(e.hallazgos) = 'object'
          AND e.hallazgos ? 'periodo'
        ORDER BY e.negocio_id, e.inicio::date, e.id DESC
    LOOP
        INSERT INTO snapshots_negocio (negocio_id, fecha, version, periodo, salud,
                                       metricas, origen, ejecucion_id)
        SELECT r.negocio_id, r.fecha, snapshot_version(),
               CASE WHEN (r.h #>> '{periodo,desde}') IS NOT NULL
                    THEN daterange((r.h #>> '{periodo,desde}')::date,
                                   (r.h #>> '{periodo,hasta}')::date, '[]') END,
               r.h -> 'salud',
               jsonb_build_object(
                 'parcial', true,
                 'reconstruido_de', 'ejecuciones.hallazgos',
                 -- Lo que NO se puede reconstruir, dicho explícitamente para que
                 -- B3 no lo confunda con "estaba en cero". `totales` figura
                 -- porque solo se recuperan los conteos de movimientos: los
                 -- importes y `base_mes` nunca estuvieron en los hallazgos.
                 'faltan', jsonb_build_array('totales.ventas', 'totales.compras',
                                             'totales.base_mes', 'margenes',
                                             'coberturas', 'proveedores',
                                             'precios_proveedor', 'ventas_producto',
                                             'pareto', 'calidad', 'umbrales'),
                 -- Lo que sí se recupera se escribe con LA FORMA DEL CONTRATO,
                 -- no con la que tenía en los hallazgos. Un snapshot parcial es
                 -- un snapshot con huecos, no un snapshot con otro esquema: si
                 -- no, B3 tendría que saber leer las dos formas.
                 'totales', jsonb_build_object(
                    'movimientos_venta',  r.h #> '{periodo,movimientos_venta}',
                    'movimientos_compra', r.h #> '{periodo,movimientos_compra}'),
                 'productos', jsonb_build_object(
                    'total',               r.h #> '{resumen,productos}',
                    'con_precio',          r.h #> '{resumen,con_precio}',
                    'margen_promedio_pct', r.h #> '{resumen,margen_promedio_pct}'),
                 -- Estos NO se pueden llevar al contrato: los hallazgos guardan
                 -- el nombre del producto y no su id, así que no son emparejables
                 -- con los de un snapshot real. Van con nombre propio para que
                 -- nadie los confunda con las claves de v1.
                 'pareto_parcial',         coalesce(r.h -> 'pareto', '[]'::jsonb),
                 'margen_bajo_parcial',    coalesce(r.h -> 'margen_bajo', '[]'::jsonb),
                 'derivas_parcial',        coalesce(r.h -> 'deriva_costo', '[]'::jsonb),
                 'baja_cobertura_parcial', coalesce(r.h -> 'baja_cobertura', '[]'::jsonb)),
               'backfill', r.id
        ON CONFLICT ON CONSTRAINT uq_snapshot_dia DO NOTHING;

        v_n := v_n + (CASE WHEN FOUND THEN 1 ELSE 0 END);
    END LOOP;

    RETURN v_n;
END;
$$;



CREATE FUNCTION public.teclado_consentimiento(p_contexto text DEFAULT ''::text) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
    SELECT jsonb_build_array(
      jsonb_build_array(jsonb_build_object(
        'texto', '✅ Acepto y continúo',
        'dato',  'acepto:' || CASE WHEN octet_length(coalesce(p_contexto,'')) <= 50
                                   THEN coalesce(p_contexto,'') ELSE '' END)),
      jsonb_build_array(jsonb_build_object(
        'texto', '🔐 Cómo trato tus datos', 'dato', '/privacidad')));
$$;



CREATE FUNCTION public.teclado_intake() RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
    SELECT CASE WHEN (SELECT count(*) FROM modulos WHERE activo) = 1
                THEN teclado_modulo((SELECT codigo FROM modulos WHERE activo))
                ELSE teclado_modulos()
           END;
$$;



CREATE FUNCTION public.teclado_markup(p_teclado jsonb, p_vars jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql STABLE
    AS $$
DECLARE
    v_max   int := coalesce((parametro(NULL, 'teclado_max_filas'))::text::int, 6);
    v_filas jsonb := '[]'::jsonb;
    v_fila  jsonb;
    v_b     jsonb;
    v_vars  jsonb;
    v_texto text;
    v_dato  text;
    v_total int := 0;
    k text; val text;
BEGIN
    IF p_teclado IS NULL OR jsonb_typeof(p_teclado) <> 'array' THEN
        RETURN jsonb_build_object('inline_keyboard', '[]'::jsonb);
    END IF;
    v_vars := CASE WHEN jsonb_typeof(p_vars) = 'object' THEN p_vars ELSE '{}'::jsonb END;

    FOR v_fila IN SELECT * FROM jsonb_array_elements(p_teclado) LOOP
        CONTINUE WHEN jsonb_typeof(v_fila) <> 'array';

        FOR v_b IN SELECT * FROM jsonb_array_elements(v_fila) LOOP
            CONTINUE WHEN jsonb_typeof(v_b) <> 'object';
            v_total := v_total + 1;

            v_texto := v_b ->> 'texto';
            v_dato  := v_b ->> 'dato';
            CONTINUE WHEN v_texto IS NULL;
            -- Sin callback_data no hay botón posible (Telegram: "Text buttons
            -- are unallowed in the inline keyboard").
            CONTINUE WHEN coalesce(v_dato, '') = '';

            FOR k, val IN SELECT * FROM jsonb_each_text(v_vars) LOOP
                v_texto := replace(v_texto, '{{' || k || '}}', coalesce(val, ''));
                v_dato  := replace(v_dato,  '{{' || k || '}}', coalesce(val, ''));
            END LOOP;

            EXIT WHEN jsonb_array_length(v_filas) >= v_max;
            -- Cada botón, su propia fila.
            -- callback_data: 1..64 bytes. Se recorta en vez de reventar; un botón
            -- que no responde se ve, un 400 se lleva todo el mensaje.
            v_filas := v_filas || jsonb_build_array(jsonb_build_array(
                jsonb_build_object('text', v_texto, 'callback_data', left(v_dato, 64))));
        END LOOP;

        EXIT WHEN jsonb_array_length(v_filas) >= v_max;
    END LOOP;

    IF v_total > v_max THEN
        RAISE WARNING 'teclado_markup: % botones para un tope de %; se recortó',
                      v_total, v_max;
    END IF;

    RETURN jsonb_build_object('inline_keyboard', v_filas);
END;
$$;



CREATE FUNCTION public.teclado_modulo(p_codigo text) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
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



CREATE FUNCTION public.teclado_modulos() RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
    SELECT coalesce(
             (SELECT jsonb_agg(jsonb_build_array(jsonb_build_object(
                       'texto', nombre, 'dato', 'mod:' || codigo)) ORDER BY orden)
                FROM modulos WHERE activo),
             '[]'::jsonb)
           || jsonb_build_array(jsonb_build_array(jsonb_build_object(
                'texto', '❓ Cómo funciona Chasqui', 'dato', '/comofunciona')));
$$;



CREATE FUNCTION public.teclado_recomendacion(p_reco_id bigint) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $_$
    SELECT jsonb_build_array(
             jsonb_build_array(jsonb_build_object(
               'texto', '✅ Ya lo hice', 'dato', 'rec:hice:' || r.id)),
             jsonb_build_array(jsonb_build_object(
               'texto', '⏭️ No aplica', 'dato', 'rec:no_aplica:' || r.id)))
           || CASE WHEN nullif(r.datos ->> 'precio_sugerido', '') IS NOT NULL
                   THEN jsonb_build_array(jsonb_build_array(jsonb_build_object(
                          'texto', '💲 Aplicar $' || miles((r.datos ->> 'precio_sugerido')::numeric),
                          'dato', 'rec:precio:' || r.id)))
                   ELSE '[]'::jsonb END
           || jsonb_build_array(jsonb_build_array(jsonb_build_object(
                'texto', '⬅️ Volver', 'dato', 'rec:list')))
    FROM recomendaciones r WHERE r.id = p_reco_id;
$_$;



CREATE FUNCTION public.teclado_recomendaciones(p_negocio_id bigint) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
    SELECT coalesce(
             (SELECT jsonb_agg(jsonb_build_array(jsonb_build_object(
                       'texto', left(titulo, 40), 'dato', 'rec:ver:' || id))
                       ORDER BY orden)
              FROM (SELECT id, titulo,
                           row_number() OVER (
                             ORDER BY CASE prioridad WHEN 'alta' THEN 1
                                                     WHEN 'media' THEN 2 ELSE 3 END,
                                      impacto_mes DESC) AS orden
                    FROM recomendaciones
                    WHERE negocio_id = p_negocio_id AND estado IN ('nueva','vigente')
                    ORDER BY orden LIMIT 5) r),
             '[]'::jsonb)
           || jsonb_build_array(jsonb_build_array(jsonb_build_object(
                'texto', '⬅️ Volver', 'dato', '/ayuda')));
$$;



CREATE FUNCTION public.teclado_tipos_negocio() RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
    SELECT coalesce(jsonb_agg(jsonb_build_array(jsonb_build_object(
             'texto', nombre, 'dato', 'tipo:' || codigo)) ORDER BY orden), '[]'::jsonb)
    FROM tipos_negocio WHERE activo;
$$;



CREATE FUNCTION public.tercero_obtener(p_negocio_id bigint, p_nit text, p_nombre text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_nit text := nullif(btrim(coalesce(p_nit, '')), '');
    v_id  bigint;
BEGIN
    IF v_nit IS NOT NULL THEN
        SELECT id INTO v_id FROM terceros
        WHERE negocio_id = p_negocio_id AND nit = v_nit;
    ELSE
        SELECT id INTO v_id FROM terceros
        WHERE negocio_id = p_negocio_id AND nit IS NULL
          AND norm_texto(nombre) = norm_texto(p_nombre);
    END IF;

    IF v_id IS NULL THEN
        INSERT INTO terceros (negocio_id, nit, nombre)
        VALUES (p_negocio_id, v_nit, coalesce(nullif(btrim(p_nombre), ''), '(sin nombre)'))
        RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END;
$$;



CREATE FUNCTION public.unidades_es(p_n numeric) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT CASE WHEN round(coalesce(p_n, 0)) = 1 THEN '1 unidad'
                ELSE round(coalesce(p_n, 0))::int::text || ' unidades' END;
$$;



CREATE FUNCTION public.usuario_de_canal(p_canal text, p_evento jsonb) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_canal text   := coalesce(nullif(p_evento ->> 'canal', ''), p_canal);
    v_ext   text   := p_evento #>> '{from,id}';
    v_chat  text   := p_evento #>> '{chat,id}';
    v_user  text   := p_evento #>> '{from,username}';
    v_datos jsonb;
    v_id    bigint;
    v_neg   bigint;
BEGIN
    IF v_ext IS NULL OR btrim(v_ext) = '' THEN
        RAISE EXCEPTION 'usuario_de_canal(%): el evento no trae from.id', v_canal;
    END IF;

    v_datos := jsonb_strip_nulls(jsonb_build_object(
                 'chat_id', v_chat, 'username', v_user));

    SELECT usuario_id INTO v_id FROM identidades
    WHERE canal = v_canal AND id_externo = v_ext;

    IF v_id IS NULL THEN
        INSERT INTO usuarios (telegram_user_id, telegram_chat_id, telegram_username)
        VALUES (CASE WHEN v_canal = 'telegram' THEN v_ext::bigint END,
                CASE WHEN v_canal = 'telegram' THEN v_chat::bigint END,
                CASE WHEN v_canal = 'telegram' THEN v_user END)
        RETURNING id INTO v_id;

        INSERT INTO identidades (canal, id_externo, usuario_id, datos)
        VALUES (v_canal, v_ext, v_id, v_datos)
        ON CONFLICT (canal, id_externo)
          DO UPDATE SET vista_en = now(), datos = identidades.datos || EXCLUDED.datos
        RETURNING usuario_id INTO v_id;
    ELSE
        UPDATE identidades SET vista_en = now(), datos = datos || v_datos
        WHERE canal = v_canal AND id_externo = v_ext;
    END IF;

    IF v_canal = 'telegram' THEN
        UPDATE usuarios SET
            telegram_chat_id  = coalesce(v_chat::bigint, telegram_chat_id),
            telegram_username = coalesce(v_user, telegram_username)
        WHERE id = v_id;
    END IF;

    -- Todo usuario tiene su negocio. Sin esto no hay dónde guardar un solo
    -- movimiento y la carga de archivos falla en silencio.
    SELECT negocio_id INTO v_neg FROM usuarios WHERE id = v_id;
    IF v_neg IS NULL THEN
        INSERT INTO negocios (nombre) VALUES ('Mi negocio') RETURNING id INTO v_neg;
        UPDATE usuarios SET negocio_id = v_neg WHERE id = v_id;
        -- Una sesión abierta antes de tener negocio también se repara: si no,
        -- los archivos de ESTA conversación siguen sin destino.
        UPDATE sesiones SET negocio_id = v_neg
         WHERE usuario_id = v_id AND negocio_id IS NULL AND cerrada_en IS NULL;
    END IF;

    RETURN v_id;
END;
$$;



CREATE FUNCTION public.usuario_de_telegram(p_evento jsonb) RETURNS bigint
    LANGUAGE sql
    AS $$
    SELECT usuario_de_canal('telegram', p_evento);
$$;



CREATE FUNCTION public.validar_cifras(p_texto text, p_hallazgos jsonb) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
    v_permitidos text[];
    v_num        text;
    v_inventadas text[] := '{}';
BEGIN
    -- Dos extracciones sobre el mismo texto, unidas:
    --
    --   `literal`  — la de siempre. Los hallazgos son JSON, así que sus valores
    --                numéricos vienen con punto decimal y sin separador de
    --                miles: basta normalizar los ceros de relleno. Se conserva
    --                tal cual para que lo permitido hoy siga permitido.
    --
    --   `humano`   — 055. Los hallazgos también traen TEXTO ya redactado por
    --                SQL ("para 142,3 días"), donde las cifras salieron de
    --                `fmt_decimal` y `miles` con formato colombiano. Cada una se
    --                expande a sus dos lecturas con la misma `cifra_variantes`
    --                que se le aplica al texto del modelo. Simetría: si las dos
    --                puntas se leen igual, un número bien copiado coincide.
    WITH literal AS (
        SELECT (regexp_matches(p_hallazgos::text, '\d+(?:\.\d+)?', 'g'))[1] AS n
    ),
    humano AS (
        SELECT (regexp_matches(p_hallazgos::text, '\d[\d.,]*', 'g'))[1] AS n
    )
    SELECT array_agg(DISTINCT v) INTO v_permitidos
    FROM (
        SELECT cifra_norm(n) AS v FROM literal
        UNION ALL
        SELECT v FROM humano, LATERAL unnest(cifra_variantes(humano.n)) AS v
    ) s
    WHERE v <> '';

    FOR v_num IN
        SELECT m[1] FROM regexp_matches(coalesce(p_texto, ''), '\d[\d.,]*', 'g') AS m
    LOOP
        -- Los números de menos de 3 dígitos se ignoran: un "3 productos" o un
        -- "80 %" no son cifras copiadas de ningún lado.
        CONTINUE WHEN length(regexp_replace(v_num, '\D', '', 'g')) < 3;
        IF NOT (cifra_variantes(v_num) && coalesce(v_permitidos, '{}')) THEN
            v_inventadas := array_append(v_inventadas, v_num);
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'ok', cardinality(v_inventadas) = 0,
        'inventadas', to_jsonb(v_inventadas));
END;
$$;



CREATE FUNCTION public.wa_payload(p_para text, p_texto text, p_markup jsonb) RETURNS jsonb
    LANGUAGE plpgsql IMMUTABLE
    AS $$
DECLARE
    v_texto  text := coalesce(nullif(btrim(coalesce(p_texto, '')), ''), '👌');
    v_btns   jsonb := '[]'::jsonb;   -- [{id,titulo}]
    v_fila   jsonb;
    v_b      jsonb;
    v_n      int;
    v_out    jsonb := '[]'::jsonb;
    v_accion jsonb;
    v_cuerpo text;
BEGIN
    FOR v_fila IN SELECT * FROM jsonb_array_elements(coalesce(p_markup -> 'inline_keyboard', '[]'::jsonb)) LOOP
        FOR v_b IN SELECT * FROM jsonb_array_elements(v_fila) LOOP
            IF v_b ? 'url' THEN
                v_texto := v_texto || E'\n\n' || (v_b ->> 'text') || ': ' || (v_b ->> 'url');
            ELSIF coalesce(v_b ->> 'callback_data', '') <> '' THEN
                v_btns := v_btns || jsonb_build_array(jsonb_build_object(
                    'id',     left(v_b ->> 'callback_data', 200),
                    'titulo', left(v_b ->> 'text', 24)));
            END IF;
        END LOOP;
    END LOOP;

    v_btns := (SELECT coalesce(jsonb_agg(e), '[]'::jsonb)
               FROM (SELECT e FROM jsonb_array_elements(v_btns) WITH ORDINALITY AS t(e, i)
                     ORDER BY i LIMIT 10) s);
    v_n := jsonb_array_length(v_btns);

    IF v_n = 0 THEN
        RETURN jsonb_build_array(jsonb_build_object(
            'messaging_product', 'whatsapp', 'to', p_para, 'type', 'text',
            'text', jsonb_build_object('body', left(v_texto, 4096),
                                       'preview_url', true)));
    END IF;

    -- Texto largo: primero el texto plano, después un interactivo corto.
    IF length(v_texto) > 1024 THEN
        v_out := jsonb_build_array(jsonb_build_object(
            'messaging_product', 'whatsapp', 'to', p_para, 'type', 'text',
            'text', jsonb_build_object('body', left(v_texto, 4096),
                                       'preview_url', true)));
        v_cuerpo := '¿Cómo seguimos?';
    ELSE
        v_cuerpo := v_texto;
    END IF;

    IF v_n <= 3 THEN
        v_accion := jsonb_build_object('buttons',
            (SELECT jsonb_agg(jsonb_build_object('type', 'reply', 'reply',
                jsonb_build_object('id', e ->> 'id', 'title', left(e ->> 'titulo', 20))))
             FROM jsonb_array_elements(v_btns) e));
        v_out := v_out || jsonb_build_array(jsonb_build_object(
            'messaging_product', 'whatsapp', 'to', p_para, 'type', 'interactive',
            'interactive', jsonb_build_object('type', 'button',
                'body',   jsonb_build_object('text', v_cuerpo),
                'action', v_accion)));
    ELSE
        v_accion := jsonb_build_object(
            'button', 'Ver opciones',
            'sections', jsonb_build_array(jsonb_build_object('rows',
                (SELECT jsonb_agg(jsonb_build_object('id', e ->> 'id',
                                                     'title', left(e ->> 'titulo', 24)))
                 FROM jsonb_array_elements(v_btns) e))));
        v_out := v_out || jsonb_build_array(jsonb_build_object(
            'messaging_product', 'whatsapp', 'to', p_para, 'type', 'interactive',
            'interactive', jsonb_build_object('type', 'list',
                'body',   jsonb_build_object('text', v_cuerpo),
                'action', v_accion)));
    END IF;

    RETURN v_out;
END;
$$;



CREATE FUNCTION public.wa_texto(p_html text) RETURNS text
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT replace(replace(replace(
             regexp_replace(
             regexp_replace(
             regexp_replace(
             regexp_replace(
             regexp_replace(
             regexp_replace(
             regexp_replace(coalesce(p_html, ''),
               '</?(b|strong)>',        '*',        'gi'),
               '</?(i|em)>',            '_',        'gi'),
               '</?(s|strike|del)>',    '~',        'gi'),
               '</?(code|pre)>',        '```',      'gi'),
               '<a[^>]*href="([^"]*)"[^>]*>([^<]*)</a>', '\2 (\1)', 'gi'),
               '<br[^>]*>',             E'\n',      'gi'),
               '<[^>]+>',               '',         'g'),
           '&lt;', '<'), '&gt;', '>'), '&amp;', '&');
$$;





CREATE TABLE public.alertas_enviadas (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    regla text NOT NULL,
    clave_objeto text NOT NULL,
    prioridad text,
    titulo text,
    enviada_en timestamp with time zone DEFAULT now() NOT NULL
);



ALTER TABLE public.alertas_enviadas ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.alertas_enviadas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE public.alias (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    texto_norm text NOT NULL,
    producto_id bigint,
    confianza numeric DEFAULT 1.0 NOT NULL,
    origen public.origen_alias DEFAULT 'pendiente'::public.origen_alias NOT NULL,
    creado_en timestamp with time zone DEFAULT now() NOT NULL
);



ALTER TABLE public.alias ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.alias_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE public.conocimiento (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    tipo text NOT NULL,
    clave text,
    titulo text NOT NULL,
    contenido text,
    datos jsonb DEFAULT '{}'::jsonb NOT NULL,
    origen text DEFAULT 'portal'::text NOT NULL,
    vigente_desde date DEFAULT CURRENT_DATE NOT NULL,
    vigente_hasta date,
    actualizado_en timestamp with time zone DEFAULT now() NOT NULL,
    actualizado_por bigint
);



ALTER TABLE public.conocimiento ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.conocimiento_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE public.conocimiento_pendiente (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    pregunta text NOT NULL,
    pregunta_norm text NOT NULL,
    veces integer DEFAULT 1 NOT NULL,
    resuelto_por bigint,
    primera_en timestamp with time zone DEFAULT now() NOT NULL,
    ultima_en timestamp with time zone DEFAULT now() NOT NULL
);



ALTER TABLE public.conocimiento_pendiente ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.conocimiento_pendiente_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE public.conteos_inventario (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    producto_id bigint NOT NULL,
    fecha date NOT NULL,
    unidades numeric NOT NULL,
    origen text DEFAULT 'portal'::text NOT NULL,
    documento_id bigint,
    nota text,
    creado_en timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT conteos_inventario_origen_check CHECK ((origen = ANY (ARRAY['portal'::text, 'archivo'::text, 'chat'::text]))),
    CONSTRAINT conteos_inventario_unidades_check CHECK ((unidades >= (0)::numeric))
);



ALTER TABLE public.conteos_inventario ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.conteos_inventario_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE public.cotizaciones (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    creado_por bigint,
    cliente text,
    notas text,
    items jsonb DEFAULT '[]'::jsonb NOT NULL,
    total numeric DEFAULT 0 NOT NULL,
    token text NOT NULL,
    estado text DEFAULT 'abierta'::text NOT NULL,
    vigente_hasta date,
    creado_en timestamp with time zone DEFAULT now() NOT NULL
);



ALTER TABLE public.cotizaciones ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.cotizaciones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE public.documentos (
    id bigint NOT NULL,
    sesion_id bigint,
    negocio_id bigint NOT NULL,
    formato_codigo text,
    nombre_archivo text,
    mime text,
    hash bytea NOT NULL,
    contenido bytea NOT NULL,
    tamano bigint,
    estado public.estado_doc DEFAULT 'pendiente'::public.estado_doc NOT NULL,
    error text,
    creado_en timestamp with time zone DEFAULT now() NOT NULL,
    filas_fuera_de_plan integer DEFAULT 0 NOT NULL,
    motivo_pendiente text
);



ALTER TABLE public.documentos ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.documentos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE public.ejecuciones (
    id bigint NOT NULL,
    sesion_id bigint,
    negocio_id bigint NOT NULL,
    servicio_codigo text,
    estado public.estado_ejec DEFAULT 'preparando'::public.estado_ejec NOT NULL,
    prompt_id bigint,
    hallazgos jsonb,
    texto text,
    pdf bytea,
    tokens_prompt integer DEFAULT 0,
    tokens_salida integer DEFAULT 0,
    costo numeric DEFAULT 0,
    error text,
    inicio timestamp with time zone DEFAULT now() NOT NULL,
    fin timestamp with time zone
);



ALTER TABLE public.ejecuciones ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.ejecuciones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE public.facturas (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    tercero_id bigint,
    documento_id bigint,
    tipo public.tipo_movimiento NOT NULL,
    numero text,
    emision date,
    vencimiento date,
    total numeric DEFAULT 0 NOT NULL,
    saldo numeric DEFAULT 0 NOT NULL,
    creado_en timestamp with time zone DEFAULT now() NOT NULL
);



ALTER TABLE public.facturas ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.facturas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE public.fallas (
    id bigint NOT NULL,
    workflow text,
    ejecucion_id bigint,
    sesion_id bigint,
    tipo text,
    transitoria boolean DEFAULT false NOT NULL,
    intentos integer DEFAULT 0 NOT NULL,
    detalle jsonb,
    creada_en timestamp with time zone DEFAULT now() NOT NULL
);



ALTER TABLE public.fallas ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.fallas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE public.formatos_documento (
    codigo text NOT NULL,
    nombre text NOT NULL,
    mime_patrones text[] DEFAULT '{}'::text[] NOT NULL,
    extensiones text[] DEFAULT '{}'::text[] NOT NULL,
    funcion_parseo text NOT NULL,
    deteccion jsonb DEFAULT '{}'::jsonb NOT NULL,
    mapeo jsonb DEFAULT '{}'::jsonb NOT NULL,
    activo boolean DEFAULT true NOT NULL,
    clase text DEFAULT 'documento'::text NOT NULL,
    huella text,
    origen text DEFAULT 'semilla'::text NOT NULL,
    CONSTRAINT formatos_documento_clase_check CHECK ((clase = ANY (ARRAY['documento'::text, 'tabular'::text]))),
    CONSTRAINT formatos_documento_origen_check CHECK ((origen = ANY (ARRAY['semilla'::text, 'inferido'::text])))
);



CREATE TABLE public.identidades (
    id bigint NOT NULL,
    canal text NOT NULL,
    id_externo text NOT NULL,
    usuario_id bigint NOT NULL,
    datos jsonb DEFAULT '{}'::jsonb NOT NULL,
    vista_en timestamp with time zone DEFAULT now() NOT NULL,
    creada_en timestamp with time zone DEFAULT now() NOT NULL
);



ALTER TABLE public.identidades ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.identidades_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE public.intenciones (
    codigo text NOT NULL,
    nombre text NOT NULL,
    patrones text[] NOT NULL,
    metrica text NOT NULL,
    periodo text DEFAULT 'todo'::text NOT NULL,
    filtros text[] DEFAULT '{}'::text[] NOT NULL,
    comparativo text,
    orden integer DEFAULT 100 NOT NULL,
    activo boolean DEFAULT true NOT NULL,
    CONSTRAINT intenciones_comparativo_check CHECK ((comparativo = ANY (ARRAY['periodo_anterior'::text, 'mismo_mes_ano_pasado'::text]))),
    CONSTRAINT intenciones_metrica_check CHECK ((metrica = ANY (ARRAY['ventas'::text, 'compras'::text, 'margen'::text, 'costo'::text, 'cobertura'::text, 'utilidad'::text, 'gasto_proveedor'::text]))),
    CONSTRAINT intenciones_periodo_check CHECK ((periodo = ANY (ARRAY['todo'::text, 'mes_actual'::text, 'mes_anterior'::text, 'ano_actual'::text, 'ultimos_30'::text])))
);



CREATE TABLE public.metricas_resultado (
    regla text NOT NULL,
    metrica text NOT NULL,
    direccion text NOT NULL,
    umbral_pct numeric DEFAULT 5 NOT NULL,
    CONSTRAINT metricas_resultado_direccion_check CHECK ((direccion = ANY (ARRAY['sube_mejor'::text, 'baja_mejor'::text]))),
    CONSTRAINT metricas_resultado_metrica_check CHECK ((metrica = ANY (ARRAY['costo'::text, 'margen_pct'::text, 'dias_cobertura'::text, 'balance'::text, 'concentracion_pct'::text, 'unidades_vendidas'::text, 'ventas'::text, 'saldo_vencido'::text])))
);



CREATE TABLE public.modulos (
    codigo text NOT NULL,
    nombre text NOT NULL,
    titular text NOT NULL,
    ayuda text NOT NULL,
    orden integer DEFAULT 100 NOT NULL,
    activo boolean DEFAULT true NOT NULL
);



CREATE TABLE public.movimientos (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    documento_id bigint,
    tipo public.tipo_movimiento NOT NULL,
    fecha date,
    producto_id bigint,
    alias_id bigint,
    cantidad numeric,
    valor_unitario numeric,
    valor_total numeric,
    impuesto numeric DEFAULT 0,
    raw jsonb,
    creado_en timestamp with time zone DEFAULT now() NOT NULL,
    tercero_id bigint
);



CREATE VIEW public.mov_visibles AS
 SELECT id,
    negocio_id,
    documento_id,
    tipo,
    fecha,
    producto_id,
    alias_id,
    cantidad,
    valor_unitario,
    valor_total,
    impuesto,
    raw,
    creado_en,
    tercero_id
   FROM public.movimientos m
  WHERE ((fecha IS NULL) OR (public.plan_desde(negocio_id) IS NULL) OR (fecha >= public.plan_desde(negocio_id)));



ALTER TABLE public.movimientos ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.movimientos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE public.negocios (
    id bigint NOT NULL,
    nombre text NOT NULL,
    nit text,
    tipo text,
    plan text DEFAULT 'free'::text NOT NULL,
    cupo_tokens_mes bigint DEFAULT 2000000 NOT NULL,
    creado_en timestamp with time zone DEFAULT now() NOT NULL
);



ALTER TABLE public.negocios ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.negocios_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE public.pagos (
    id bigint NOT NULL,
    factura_id bigint NOT NULL,
    fecha date DEFAULT CURRENT_DATE NOT NULL,
    valor numeric NOT NULL,
    medio text,
    origen text DEFAULT 'portal'::text NOT NULL,
    usuario_id bigint,
    creado_en timestamp with time zone DEFAULT now() NOT NULL
);



ALTER TABLE public.pagos ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.pagos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE public.parametros (
    negocio_id bigint,
    clave text NOT NULL,
    valor jsonb NOT NULL
);



CREATE TABLE public.plantillas (
    clave text NOT NULL,
    canal text DEFAULT 'telegram'::text NOT NULL,
    cuerpo text NOT NULL,
    formato text DEFAULT 'markdown'::text NOT NULL,
    variables jsonb DEFAULT '[]'::jsonb NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    activo boolean DEFAULT true NOT NULL,
    teclado jsonb DEFAULT '[]'::jsonb NOT NULL,
    crudas jsonb DEFAULT '[]'::jsonb NOT NULL,
    reemplaza boolean DEFAULT false NOT NULL
);



CREATE TABLE public.portal_tokens (
    id bigint NOT NULL,
    usuario_id bigint NOT NULL,
    hash bytea NOT NULL,
    expira_en timestamp with time zone NOT NULL,
    usado_en timestamp with time zone,
    creado_en timestamp with time zone DEFAULT now() NOT NULL
);



ALTER TABLE public.portal_tokens ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.portal_tokens_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE public.productos (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    nombre_canonico text NOT NULL,
    unidad text,
    categoria text,
    creado_en timestamp with time zone DEFAULT now() NOT NULL,
    codigo_barras text
);



ALTER TABLE public.productos ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.productos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE public.prompts (
    id bigint NOT NULL,
    servicio_codigo text NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    sistema text NOT NULL,
    usuario text NOT NULL,
    modelo text DEFAULT 'deepseek-v4-flash'::text NOT NULL,
    temperatura numeric DEFAULT 0.2 NOT NULL,
    max_tokens integer DEFAULT 2000 NOT NULL,
    activo boolean DEFAULT true NOT NULL
);



ALTER TABLE public.prompts ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.prompts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE public.prompts_tecnicos (
    clave text NOT NULL,
    sistema text NOT NULL,
    usuario text NOT NULL,
    modelo text DEFAULT 'deepseek-v4-flash'::text NOT NULL,
    temperatura numeric DEFAULT 0.0 NOT NULL,
    max_tokens integer DEFAULT 800 NOT NULL,
    activo boolean DEFAULT true NOT NULL
);



CREATE TABLE public.recomendaciones (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    regla text NOT NULL,
    clave_objeto text NOT NULL,
    titulo text NOT NULL,
    problema text,
    impacto text,
    impacto_mes numeric,
    impacto_tipo text,
    prioridad text,
    opciones jsonb DEFAULT '[]'::jsonb NOT NULL,
    origen_stock text,
    estado text DEFAULT 'nueva'::text NOT NULL,
    cerrada_por text,
    resultado text,
    detectada_en timestamp with time zone DEFAULT now() NOT NULL,
    vista_en timestamp with time zone,
    revisada_en timestamp with time zone DEFAULT now() NOT NULL,
    cerrada_en timestamp with time zone,
    veces_vista integer DEFAULT 0 NOT NULL,
    ejecucion_id bigint,
    datos jsonb DEFAULT '{}'::jsonb NOT NULL,
    icono text,
    CONSTRAINT recomendaciones_cerrada_por_check CHECK ((cerrada_por = ANY (ARRAY['dato'::text, 'accion_usuario'::text, 'sin_datos'::text]))),
    CONSTRAINT recomendaciones_check CHECK (((estado = ANY (ARRAY['nueva'::text, 'vigente'::text])) = (cerrada_en IS NULL))),
    CONSTRAINT recomendaciones_estado_check CHECK ((estado = ANY (ARRAY['nueva'::text, 'vigente'::text, 'resuelta'::text, 'ignorada'::text, 'caducada'::text]))),
    CONSTRAINT recomendaciones_resultado_check CHECK ((resultado = ANY (ARRAY['positivo'::text, 'neutro'::text, 'negativo'::text])))
);



ALTER TABLE public.recomendaciones ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.recomendaciones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE public.schema_migraciones (
    archivo text NOT NULL,
    aplicada_en timestamp with time zone DEFAULT now() NOT NULL
);



CREATE TABLE public.servicios (
    codigo text NOT NULL,
    nombre text NOT NULL,
    descripcion text,
    orden integer DEFAULT 100 NOT NULL,
    activo boolean DEFAULT true NOT NULL,
    funcion_hallazgos text DEFAULT 'hallazgos_generar'::text NOT NULL,
    entrada text DEFAULT 'archivos'::text NOT NULL,
    modulo_codigo text,
    CONSTRAINT servicios_entrada_ck CHECK ((entrada = ANY (ARRAY['archivos'::text, 'texto'::text])))
);



CREATE TABLE public.servicios_entradas (
    servicio_codigo text NOT NULL,
    formato_codigo text NOT NULL,
    obligatorio boolean DEFAULT true NOT NULL,
    min_archivos integer DEFAULT 1 NOT NULL,
    max_archivos integer
);



CREATE TABLE public.sesiones (
    id bigint NOT NULL,
    usuario_id bigint NOT NULL,
    negocio_id bigint,
    servicio_codigo text,
    paso text,
    estado public.estado_sesion DEFAULT 'intake'::public.estado_sesion NOT NULL,
    contexto jsonb DEFAULT '{}'::jsonb NOT NULL,
    ultima_actividad timestamp with time zone DEFAULT now() NOT NULL,
    creada_en timestamp with time zone DEFAULT now() NOT NULL,
    cerrada_en timestamp with time zone,
    panel_mensaje_id bigint,
    analisis_pedido_en timestamp with time zone
);



ALTER TABLE public.sesiones ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.sesiones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE public.sinonimos_columna (
    canonica text NOT NULL,
    patron text NOT NULL,
    prioridad integer DEFAULT 20 NOT NULL,
    CONSTRAINT sinonimos_canonica_valida CHECK ((canonica = ANY (ARRAY['fecha'::text, 'producto'::text, 'categoria'::text, 'cantidad'::text, 'valor_unitario'::text, 'valor_total'::text, 'codigo'::text, 'unidad'::text, 'impuesto'::text])))
);



CREATE TABLE public.snapshots_negocio (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    fecha date DEFAULT CURRENT_DATE NOT NULL,
    version integer NOT NULL,
    periodo daterange,
    salud jsonb,
    metricas jsonb NOT NULL,
    origen text NOT NULL,
    ejecucion_id bigint,
    creado_en timestamp with time zone DEFAULT now() NOT NULL
);



ALTER TABLE public.snapshots_negocio ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.snapshots_negocio_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE public.terceros (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    nit text,
    nombre text NOT NULL,
    creado_en timestamp with time zone DEFAULT now() NOT NULL
);



ALTER TABLE public.terceros ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.terceros_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE public.tipos_negocio (
    codigo text NOT NULL,
    nombre text NOT NULL,
    orden integer DEFAULT 100 NOT NULL,
    activo boolean DEFAULT true NOT NULL
);



CREATE TABLE public.usuarios (
    id bigint NOT NULL,
    negocio_id bigint,
    telegram_user_id bigint,
    telegram_chat_id bigint,
    telegram_username text,
    nombre text,
    rol public.rol_usuario DEFAULT 'operador'::public.rol_usuario NOT NULL,
    autorizacion_datos boolean DEFAULT false NOT NULL,
    autorizacion_fecha timestamp with time zone,
    creado_en timestamp with time zone DEFAULT now() NOT NULL
);



ALTER TABLE public.usuarios ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.usuarios_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE VIEW public.v_balance_unidades AS
 WITH ultimo_conteo AS (
         SELECT DISTINCT ON (conteos_inventario.negocio_id, conteos_inventario.producto_id) conteos_inventario.negocio_id,
            conteos_inventario.producto_id,
            conteos_inventario.fecha AS conteo_fecha,
            conteos_inventario.unidades AS conteo_unidades
           FROM public.conteos_inventario
          ORDER BY conteos_inventario.negocio_id, conteos_inventario.producto_id, conteos_inventario.fecha DESC, conteos_inventario.id DESC
        )
 SELECT p.negocio_id,
    p.id AS producto_id,
    COALESCE(sum(m.cantidad) FILTER (WHERE (m.tipo = 'compra'::public.tipo_movimiento)), (0)::numeric) AS compradas,
    COALESCE(sum(m.cantidad) FILTER (WHERE (m.tipo = 'venta'::public.tipo_movimiento)), (0)::numeric) AS vendidas,
        CASE
            WHEN (c.conteo_fecha IS NULL) THEN (COALESCE(sum(m.cantidad) FILTER (WHERE (m.tipo = 'compra'::public.tipo_movimiento)), (0)::numeric) - COALESCE(sum(m.cantidad) FILTER (WHERE (m.tipo = 'venta'::public.tipo_movimiento)), (0)::numeric))
            ELSE ((c.conteo_unidades + COALESCE(sum(m.cantidad) FILTER (WHERE ((m.tipo = 'compra'::public.tipo_movimiento) AND (m.fecha > c.conteo_fecha))), (0)::numeric)) - COALESCE(sum(m.cantidad) FILTER (WHERE ((m.tipo = 'venta'::public.tipo_movimiento) AND (m.fecha > c.conteo_fecha))), (0)::numeric))
        END AS balance,
        CASE
            WHEN (c.conteo_fecha IS NULL) THEN 'estimado'::text
            WHEN (count(*) FILTER (WHERE (m.fecha > c.conteo_fecha)) = 0) THEN 'conteo'::text
            ELSE 'calculado'::text
        END AS origen_stock,
    c.conteo_fecha,
    c.conteo_unidades
   FROM ((public.productos p
     LEFT JOIN ultimo_conteo c ON (((c.negocio_id = p.negocio_id) AND (c.producto_id = p.id))))
     LEFT JOIN public.mov_visibles m ON (((m.producto_id = p.id) AND (m.negocio_id = p.negocio_id))))
  GROUP BY p.negocio_id, p.id, c.conteo_fecha, c.conteo_unidades;



CREATE VIEW public.v_calidad_matching AS
 SELECT n.id AS negocio_id,
    count(a.id) AS aliases,
    count(a.id) FILTER (WHERE (a.producto_id IS NOT NULL)) AS resueltos,
    count(a.id) FILTER (WHERE (a.producto_id IS NULL)) AS pendientes,
    count(a.id) FILTER (WHERE (a.origen = 'trigram'::public.origen_alias)) AS por_trigram,
    count(a.id) FILTER (WHERE (a.origen = 'manual'::public.origen_alias)) AS confirmados_manual,
    round(((100.0 * (count(a.id) FILTER (WHERE (a.producto_id IS NOT NULL)))::numeric) / (NULLIF(count(a.id), 0))::numeric), 1) AS pct_resuelto,
    m.movs_sin_producto,
    m.dinero_sin_producto,
    m.pct_dinero_fuera
   FROM ((public.negocios n
     LEFT JOIN public.alias a ON ((a.negocio_id = n.id)))
     CROSS JOIN LATERAL ( SELECT count(*) FILTER (WHERE (v.producto_id IS NULL)) AS movs_sin_producto,
            round(COALESCE(sum(v.valor_total) FILTER (WHERE (v.producto_id IS NULL)), (0)::numeric)) AS dinero_sin_producto,
            round(((100.0 * COALESCE(sum(v.valor_total) FILTER (WHERE (v.producto_id IS NULL)), (0)::numeric)) / NULLIF(sum(v.valor_total), (0)::numeric)), 1) AS pct_dinero_fuera
           FROM public.mov_visibles v
          WHERE (v.negocio_id = n.id)) m)
  GROUP BY n.id, m.movs_sin_producto, m.dinero_sin_producto, m.pct_dinero_fuera;



CREATE VIEW public.v_cartera_edades AS
 SELECT negocio_id,
    tipo,
        CASE
            WHEN ((vencimiento IS NULL) OR (vencimiento >= CURRENT_DATE)) THEN 'al_dia'::text
            WHEN ((CURRENT_DATE - vencimiento) <= 30) THEN 'd1_30'::text
            WHEN ((CURRENT_DATE - vencimiento) <= 60) THEN 'd31_60'::text
            WHEN ((CURRENT_DATE - vencimiento) <= 90) THEN 'd61_90'::text
            ELSE 'd90_mas'::text
        END AS edad,
    count(*) AS facturas,
    sum(saldo) AS saldo
   FROM public.facturas
  WHERE (saldo > (0)::numeric)
  GROUP BY negocio_id, tipo,
        CASE
            WHEN ((vencimiento IS NULL) OR (vencimiento >= CURRENT_DATE)) THEN 'al_dia'::text
            WHEN ((CURRENT_DATE - vencimiento) <= 30) THEN 'd1_30'::text
            WHEN ((CURRENT_DATE - vencimiento) <= 60) THEN 'd31_60'::text
            WHEN ((CURRENT_DATE - vencimiento) <= 90) THEN 'd61_90'::text
            ELSE 'd90_mas'::text
        END;



CREATE VIEW public.v_cartera_tercero AS
 SELECT f.negocio_id,
    f.tipo,
    t.id AS tercero_id,
    t.nombre,
    t.nit,
    count(*) AS facturas,
    sum(f.saldo) AS saldo,
    min(f.vencimiento) AS vencimiento_mas_antiguo,
    max((CURRENT_DATE - f.vencimiento)) FILTER (WHERE (f.vencimiento < CURRENT_DATE)) AS dias_mora
   FROM (public.facturas f
     JOIN public.terceros t ON ((t.id = f.tercero_id)))
  WHERE (f.saldo > (0)::numeric)
  GROUP BY f.negocio_id, f.tipo, t.id, t.nombre, t.nit;



CREATE VIEW public.v_conocimiento_cobertura AS
 SELECT n.id AS negocio_id,
    n.nombre AS negocio,
    count(c.id) AS hechos,
    count(c.id) FILTER (WHERE (c.tipo = 'precio'::text)) AS precios,
    count(c.id) FILTER (WHERE (c.origen = 'chat'::text)) AS desde_chat,
    ( SELECT count(*) AS count
           FROM public.conocimiento_pendiente p
          WHERE ((p.negocio_id = n.id) AND (p.resuelto_por IS NULL))) AS pendientes,
    max(c.actualizado_en) AS ultimo_cambio
   FROM (public.negocios n
     LEFT JOIN public.conocimiento c ON ((c.negocio_id = n.id)))
  GROUP BY n.id, n.nombre;



CREATE VIEW public.v_conocimiento_faltante AS
 SELECT p.id,
    p.negocio_id,
    n.nombre AS negocio,
    p.pregunta,
    p.veces,
    p.primera_en,
    p.ultima_en,
    s.id AS candidato_id,
    s.titulo AS candidato,
    s.parecido
   FROM ((public.conocimiento_pendiente p
     JOIN public.negocios n ON ((n.id = p.negocio_id)))
     LEFT JOIN LATERAL ( SELECT c.id,
            c.titulo,
            round((public.word_similarity(p.pregunta_norm, public.norm_texto(((c.titulo || ' '::text) || COALESCE(c.contenido, ''::text)))))::numeric, 3) AS parecido
           FROM public.conocimiento c
          WHERE ((c.negocio_id = p.negocio_id) AND (public.word_similarity(p.pregunta_norm, public.norm_texto(((c.titulo || ' '::text) || COALESCE(c.contenido, ''::text)))) >= (0.30)::double precision))
          ORDER BY (round((public.word_similarity(p.pregunta_norm, public.norm_texto(((c.titulo || ' '::text) || COALESCE(c.contenido, ''::text)))))::numeric, 3)) DESC
         LIMIT 1) s ON (true))
  WHERE (p.resuelto_por IS NULL)
  ORDER BY p.veces DESC, p.ultima_en DESC;



CREATE VIEW public.v_consumo_negocio AS
 SELECT n.id AS negocio_id,
    n.nombre,
    n.cupo_tokens_mes,
    COALESCE(sum((e.tokens_prompt + e.tokens_salida)) FILTER (WHERE (e.inicio >= date_trunc('month'::text, now()))), (0)::bigint) AS tokens_mes,
    COALESCE(sum(e.costo) FILTER (WHERE (e.inicio >= date_trunc('month'::text, now()))), (0)::numeric) AS costo_mes,
    count(e.id) FILTER (WHERE ((e.inicio >= date_trunc('month'::text, now())) AND (e.estado = 'completada'::public.estado_ejec))) AS ejecuciones_mes
   FROM (public.negocios n
     LEFT JOIN public.ejecuciones e ON ((e.negocio_id = n.id)))
  GROUP BY n.id, n.nombre, n.cupo_tokens_mes;



CREATE VIEW public.v_costo_actual_producto AS
 SELECT DISTINCT ON (negocio_id, producto_id) negocio_id,
    producto_id,
    valor_unitario AS costo_actual,
    fecha AS fecha_costo
   FROM public.mov_visibles m
  WHERE ((tipo = 'compra'::public.tipo_movimiento) AND (producto_id IS NOT NULL) AND (valor_unitario IS NOT NULL))
  ORDER BY negocio_id, producto_id, fecha DESC NULLS LAST, id DESC;



CREATE VIEW public.v_deriva_costo AS
 WITH compras AS (
         SELECT mov_visibles.negocio_id,
            mov_visibles.producto_id,
            mov_visibles.valor_unitario,
            mov_visibles.fecha,
            mov_visibles.id,
            first_value(mov_visibles.valor_unitario) OVER w AS costo_ini,
            last_value(mov_visibles.valor_unitario) OVER w AS costo_fin
           FROM public.mov_visibles
          WHERE ((mov_visibles.tipo = 'compra'::public.tipo_movimiento) AND (mov_visibles.producto_id IS NOT NULL) AND (mov_visibles.valor_unitario IS NOT NULL))
          WINDOW w AS (PARTITION BY mov_visibles.negocio_id, mov_visibles.producto_id ORDER BY mov_visibles.fecha NULLS FIRST, mov_visibles.id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
        )
 SELECT DISTINCT negocio_id,
    producto_id,
    costo_ini,
    costo_fin,
    (costo_fin - costo_ini) AS deriva_abs,
    round((((costo_fin - costo_ini) / NULLIF(costo_ini, (0)::numeric)) * (100)::numeric), 2) AS deriva_pct
   FROM compras;



CREATE VIEW public.v_ejecuciones_fallidas AS
 SELECT id AS ejecucion_id,
    negocio_id,
    servicio_codigo,
    error,
    inicio,
    fin
   FROM public.ejecuciones e
  WHERE ((estado = 'fallida'::public.estado_ejec) AND (inicio >= (now() - '24:00:00'::interval)))
  ORDER BY inicio DESC;



CREATE VIEW public.v_embudo_servicios AS
 SELECT servicio_codigo,
    count(*) AS iniciadas,
    count(*) FILTER (WHERE (estado = 'completada'::public.estado_sesion)) AS completadas,
    count(*) FILTER (WHERE (estado = 'expirada'::public.estado_sesion)) AS abandonadas,
    count(*) FILTER (WHERE (estado = 'fallida'::public.estado_sesion)) AS fallidas,
    mode() WITHIN GROUP (ORDER BY paso) FILTER (WHERE (estado = ANY (ARRAY['expirada'::public.estado_sesion, 'fallida'::public.estado_sesion]))) AS paso_de_caida
   FROM public.sesiones
  GROUP BY servicio_codigo;



CREATE VIEW public.v_precio_actual_producto AS
 SELECT DISTINCT ON (negocio_id, producto_id) negocio_id,
    producto_id,
    valor_unitario AS precio_actual,
    fecha AS fecha_precio
   FROM public.mov_visibles m
  WHERE ((tipo = 'venta'::public.tipo_movimiento) AND (producto_id IS NOT NULL) AND (valor_unitario IS NOT NULL))
  ORDER BY negocio_id, producto_id, fecha DESC NULLS LAST, id DESC;



CREATE VIEW public.v_margen_producto AS
 SELECT p.negocio_id,
    p.id AS producto_id,
    p.nombre_canonico,
    c.costo_actual,
    pr.precio_actual,
    (pr.precio_actual - c.costo_actual) AS margen_abs,
    round((((pr.precio_actual - c.costo_actual) / NULLIF(pr.precio_actual, (0)::numeric)) * (100)::numeric), 2) AS margen_pct
   FROM ((public.productos p
     LEFT JOIN public.v_costo_actual_producto c ON (((c.negocio_id = p.negocio_id) AND (c.producto_id = p.id))))
     LEFT JOIN public.v_precio_actual_producto pr ON (((pr.negocio_id = p.negocio_id) AND (pr.producto_id = p.id))));



CREATE VIEW public.v_negocios_alertables AS
 SELECT n.id AS negocio_id,
    u.id AS usuario_id,
    u.telegram_chat_id AS chat_id,
    m.ultimo_dato,
    e.ultimo_analisis
   FROM (((public.negocios n
     JOIN LATERAL ( SELECT usuarios.id,
            usuarios.telegram_chat_id
           FROM public.usuarios
          WHERE ((usuarios.negocio_id = n.id) AND usuarios.autorizacion_datos AND (usuarios.telegram_chat_id IS NOT NULL))
          ORDER BY usuarios.id
         LIMIT 1) u ON (true))
     CROSS JOIN LATERAL ( SELECT max(mov_visibles.creado_en) AS ultimo_dato
           FROM public.mov_visibles
          WHERE (mov_visibles.negocio_id = n.id)) m)
     CROSS JOIN LATERAL ( SELECT max(ejecuciones.fin) AS ultimo_analisis
           FROM public.ejecuciones
          WHERE ((ejecuciones.negocio_id = n.id) AND (ejecuciones.estado = 'completada'::public.estado_ejec) AND (ejecuciones.servicio_codigo IN ( SELECT servicios.codigo
                   FROM public.servicios
                  WHERE (servicios.entrada = 'archivos'::text))))) e)
  WHERE ((m.ultimo_dato IS NOT NULL) AND ((e.ultimo_analisis IS NULL) OR (m.ultimo_dato > e.ultimo_analisis)));



CREATE VIEW public.v_negocios_informe_periodico AS
 SELECT n.id AS negocio_id,
    u.id AS usuario_id,
    u.telegram_chat_id AS chat_id,
    e.ultimo_analisis,
    m.movs_nuevos
   FROM (((public.negocios n
     JOIN LATERAL ( SELECT usuarios.id,
            usuarios.telegram_chat_id
           FROM public.usuarios
          WHERE ((usuarios.negocio_id = n.id) AND usuarios.autorizacion_datos AND (usuarios.telegram_chat_id IS NOT NULL))
          ORDER BY usuarios.id
         LIMIT 1) u ON (true))
     CROSS JOIN LATERAL ( SELECT max(ejecuciones.fin) AS ultimo_analisis
           FROM public.ejecuciones
          WHERE ((ejecuciones.negocio_id = n.id) AND (ejecuciones.estado = 'completada'::public.estado_ejec) AND (ejecuciones.servicio_codigo IN ( SELECT servicios.codigo
                   FROM public.servicios
                  WHERE (servicios.entrada = 'archivos'::text))))) e)
     CROSS JOIN LATERAL ( SELECT count(*) AS movs_nuevos
           FROM public.mov_visibles
          WHERE ((mov_visibles.negocio_id = n.id) AND ((e.ultimo_analisis IS NULL) OR (mov_visibles.creado_en > e.ultimo_analisis)))) m)
  WHERE ((e.ultimo_analisis IS NOT NULL) AND (e.ultimo_analisis < (now() - make_interval(days => COALESCE(((public.parametro(NULL::bigint, 'informe_periodico_dias'::text))::text)::integer, 30)))) AND (m.movs_nuevos >= COALESCE(((public.parametro(NULL::bigint, 'informe_periodico_min_movs'::text))::text)::integer, 10)) AND (NOT (EXISTS ( SELECT 1
           FROM public.ejecuciones x
          WHERE ((x.negocio_id = n.id) AND (x.estado = ANY (ARRAY['preparando'::public.estado_ejec, 'procesando'::public.estado_ejec, 'validando'::public.estado_ejec])))))));



CREATE VIEW public.v_pareto_utilidad AS
 WITH util AS (
         SELECT m.negocio_id,
            m.producto_id,
            sum(((m.valor_unitario - c.costo_actual) * m.cantidad)) AS utilidad
           FROM (public.mov_visibles m
             JOIN public.v_costo_actual_producto c ON (((c.negocio_id = m.negocio_id) AND (c.producto_id = m.producto_id))))
          WHERE ((m.tipo = 'venta'::public.tipo_movimiento) AND (m.producto_id IS NOT NULL))
          GROUP BY m.negocio_id, m.producto_id
        ), ranked AS (
         SELECT util.negocio_id,
            util.producto_id,
            util.utilidad,
            sum(util.utilidad) OVER (PARTITION BY util.negocio_id) AS utilidad_total,
            sum(util.utilidad) OVER (PARTITION BY util.negocio_id ORDER BY util.utilidad DESC ROWS UNBOUNDED PRECEDING) AS utilidad_acum
           FROM util
        )
 SELECT negocio_id,
    producto_id,
    utilidad,
    round(((utilidad / NULLIF(utilidad_total, (0)::numeric)) * (100)::numeric), 2) AS pct_utilidad,
    round(((utilidad_acum / NULLIF(utilidad_total, (0)::numeric)) * (100)::numeric), 2) AS pct_acumulado
   FROM ranked
  ORDER BY negocio_id, utilidad DESC;



CREATE VIEW public.v_perfil_negocio AS
 SELECT id AS negocio_id,
    nombre,
    plan,
    tipo AS tipo_codigo,
    ( SELECT tipos_negocio.nombre
           FROM public.tipos_negocio
          WHERE (tipos_negocio.codigo = n.tipo)) AS tipo_nombre,
    (NULLIF(btrim(COALESCE(nit, ''::text)), ''::text) IS NOT NULL) AS tiene_nit,
    ( SELECT jsonb_build_object('desde', min(mov_visibles.fecha), 'hasta', max(mov_visibles.fecha), 'meses', round(GREATEST((((max(mov_visibles.fecha) - min(mov_visibles.fecha)))::numeric / 30.0), (0)::numeric), 1), 'movimientos', count(*), 'ventas', round(COALESCE(sum(mov_visibles.valor_total) FILTER (WHERE (mov_visibles.tipo = 'venta'::public.tipo_movimiento)), (0)::numeric)), 'compras', round(COALESCE(sum(mov_visibles.valor_total) FILTER (WHERE (mov_visibles.tipo = 'compra'::public.tipo_movimiento)), (0)::numeric))) AS jsonb_build_object
           FROM public.mov_visibles
          WHERE (mov_visibles.negocio_id = n.id)) AS periodo,
    ( SELECT jsonb_build_object('total', count(*), 'con_precio', count(*) FILTER (WHERE (v_margen_producto.precio_actual IS NOT NULL)), 'margen_mediano_pct', round((percentile_cont((0.5)::double precision) WITHIN GROUP (ORDER BY ((v_margen_producto.margen_pct)::double precision)))::numeric, 2), 'margen_min_pct', round(min(v_margen_producto.margen_pct), 2), 'margen_max_pct', round(max(v_margen_producto.margen_pct), 2)) AS jsonb_build_object
           FROM public.v_margen_producto
          WHERE (v_margen_producto.negocio_id = n.id)) AS productos,
    ( SELECT COALESCE(jsonb_agg(jsonb_build_object('producto_id', pa.producto_id, 'nombre', p.nombre_canonico, 'utilidad', round(pa.utilidad), 'pct_utilidad', pa.pct_utilidad) ORDER BY pa.utilidad DESC), '[]'::jsonb) AS "coalesce"
           FROM (public.v_pareto_utilidad pa
             JOIN public.productos p ON ((p.id = pa.producto_id)))
          WHERE ((pa.negocio_id = n.id) AND (pa.pct_acumulado <= (80)::numeric))) AS top_productos,
    ( SELECT jsonb_build_object('total', count(*), 'principal', (array_agg(g.prov ORDER BY g.gasto DESC))[1], 'concentracion_pct', round(((max(g.gasto) * 100.0) / NULLIF(sum(g.gasto), (0)::numeric)), 1), 'detalle', COALESCE(jsonb_agg(jsonb_build_object('proveedor', g.prov, 'gasto', round(g.gasto)) ORDER BY g.gasto DESC), '[]'::jsonb)) AS jsonb_build_object
           FROM ( SELECT NULLIF(btrim(COALESCE((mov_visibles.raw ->> 'proveedor'::text), ''::text)), ''::text) AS prov,
                    sum(mov_visibles.valor_total) AS gasto
                   FROM public.mov_visibles
                  WHERE ((mov_visibles.negocio_id = n.id) AND (mov_visibles.tipo = 'compra'::public.tipo_movimiento) AND (NULLIF(btrim(COALESCE((mov_visibles.raw ->> 'proveedor'::text), ''::text)), ''::text) IS NOT NULL))
                  GROUP BY NULLIF(btrim(COALESCE((mov_visibles.raw ->> 'proveedor'::text), ''::text)), ''::text)) g) AS proveedores,
    ( SELECT jsonb_build_object('suficiente', ((max(mov_visibles.fecha) - min(mov_visibles.fecha)) >= 365), 'por_mes', COALESCE(( SELECT jsonb_agg(jsonb_build_object('mes', s.m, 'ventas', round(s.v), 'meses_observados', s.obs) ORDER BY s.m) AS jsonb_agg
                   FROM ( SELECT (EXTRACT(month FROM mov_visibles_1.fecha))::integer AS m,
                            sum(mov_visibles_1.valor_total) AS v,
                            count(DISTINCT date_trunc('month'::text, (mov_visibles_1.fecha)::timestamp with time zone)) AS obs
                           FROM public.mov_visibles mov_visibles_1
                          WHERE ((mov_visibles_1.negocio_id = n.id) AND (mov_visibles_1.tipo = 'venta'::public.tipo_movimiento) AND (mov_visibles_1.fecha IS NOT NULL))
                          GROUP BY ((EXTRACT(month FROM mov_visibles_1.fecha))::integer)) s), '[]'::jsonb)) AS jsonb_build_object
           FROM public.mov_visibles
          WHERE ((mov_visibles.negocio_id = n.id) AND (mov_visibles.fecha IS NOT NULL))) AS estacionalidad,
    ( SELECT COALESCE(jsonb_agg(jsonb_build_object('regla', r.regla, 'veces', r.veces, 'abiertas', r.abiertas, 'resueltas', r.resueltas, 'primera_vez', r.primera) ORDER BY r.veces DESC), '[]'::jsonb) AS "coalesce"
           FROM ( SELECT recomendaciones.regla,
                    count(*) AS veces,
                    count(*) FILTER (WHERE (recomendaciones.estado = ANY (ARRAY['nueva'::text, 'vigente'::text]))) AS abiertas,
                    count(*) FILTER (WHERE (recomendaciones.estado = 'resuelta'::text)) AS resueltas,
                    (min(recomendaciones.detectada_en))::date AS primera
                   FROM public.recomendaciones
                  WHERE (recomendaciones.negocio_id = n.id)
                  GROUP BY recomendaciones.regla) r) AS problemas_recurrentes,
    ( SELECT jsonb_build_object('cerradas_total', count(*) FILTER (WHERE (recomendaciones.estado <> ALL (ARRAY['nueva'::text, 'vigente'::text]))), 'por_dato', count(*) FILTER (WHERE (recomendaciones.cerrada_por = 'dato'::text)), 'por_accion', count(*) FILTER (WHERE (recomendaciones.cerrada_por = 'accion_usuario'::text)), 'ignoradas', count(*) FILTER (WHERE (recomendaciones.estado = 'ignorada'::text)), 'sin_datos', count(*) FILTER (WHERE (recomendaciones.cerrada_por = 'sin_datos'::text))) AS jsonb_build_object
           FROM public.recomendaciones
          WHERE (recomendaciones.negocio_id = n.id)) AS acciones,
    ( SELECT jsonb_build_object('snapshots', count(*), 'ultimo', max(snapshots_negocio.fecha), 'serie', COALESCE(( SELECT jsonb_agg(jsonb_build_object('fecha', u.fecha, 'indice', (u.salud -> 'indice'::text)) ORDER BY u.fecha) AS jsonb_agg
                   FROM ( SELECT snapshots_negocio_1.fecha,
                            snapshots_negocio_1.salud
                           FROM public.snapshots_negocio snapshots_negocio_1
                          WHERE (snapshots_negocio_1.negocio_id = n.id)
                          ORDER BY snapshots_negocio_1.fecha DESC
                         LIMIT 12) u), '[]'::jsonb)) AS jsonb_build_object
           FROM public.snapshots_negocio
          WHERE (snapshots_negocio.negocio_id = n.id)) AS salud_historia,
    ( SELECT jsonb_build_object('movs_sin_producto', v_calidad_matching.movs_sin_producto, 'dinero_sin_producto', v_calidad_matching.dinero_sin_producto, 'pct_dinero_fuera', COALESCE(v_calidad_matching.pct_dinero_fuera, (0)::numeric), 'productos_stock_estimado', ( SELECT count(*) AS count
                   FROM public.v_balance_unidades
                  WHERE ((v_balance_unidades.negocio_id = n.id) AND (v_balance_unidades.origen_stock = 'estimado'::text)))) AS jsonb_build_object
           FROM public.v_calidad_matching
          WHERE (v_calidad_matching.negocio_id = n.id)) AS calidad
   FROM public.negocios n;



CREATE VIEW public.v_proveedor_mas_barato AS
 SELECT DISTINCT ON (negocio_id, producto_id) negocio_id,
    producto_id,
    proveedor,
    round(precio_prom) AS precio,
    compras,
    ultima_compra
   FROM ( SELECT m.negocio_id,
            m.producto_id,
            NULLIF(btrim(COALESCE((m.raw ->> 'proveedor'::text), ''::text)), ''::text) AS proveedor,
            (sum(m.valor_total) / NULLIF(sum(m.cantidad), (0)::numeric)) AS precio_prom,
            count(*) AS compras,
            max(m.fecha) AS ultima_compra
           FROM public.mov_visibles m
          WHERE ((m.tipo = 'compra'::public.tipo_movimiento) AND (m.producto_id IS NOT NULL) AND (m.cantidad > (0)::numeric) AND (m.valor_total > (0)::numeric) AND (NULLIF(btrim(COALESCE((m.raw ->> 'proveedor'::text), ''::text)), ''::text) IS NOT NULL))
          GROUP BY m.negocio_id, m.producto_id, NULLIF(btrim(COALESCE((m.raw ->> 'proveedor'::text), ''::text)), ''::text)) s
  ORDER BY negocio_id, producto_id, precio_prom, ultima_compra DESC;



CREATE VIEW public.v_rotacion_producto AS
 WITH ventas AS (
         SELECT mov_visibles.negocio_id,
            mov_visibles.producto_id,
            sum(mov_visibles.cantidad) AS unidades,
            GREATEST((max(mov_visibles.fecha) - min(mov_visibles.fecha)), 1) AS dias_ventana
           FROM public.mov_visibles
          WHERE ((mov_visibles.tipo = 'venta'::public.tipo_movimiento) AND (mov_visibles.producto_id IS NOT NULL))
          GROUP BY mov_visibles.negocio_id, mov_visibles.producto_id
        )
 SELECT v.negocio_id,
    v.producto_id,
    v.unidades,
    v.dias_ventana,
    round((v.unidades / (v.dias_ventana)::numeric), 3) AS unidades_por_dia,
        CASE
            WHEN (v.unidades > (0)::numeric) THEN round((b.balance / (v.unidades / (v.dias_ventana)::numeric)), 1)
            ELSE NULL::numeric
        END AS dias_cobertura,
    b.origen_stock
   FROM (ventas v
     LEFT JOIN public.v_balance_unidades b ON (((b.negocio_id = v.negocio_id) AND (b.producto_id = v.producto_id))));



CREATE VIEW public.v_salud_ingesta AS
 WITH por_estado AS (
         SELECT documentos.negocio_id,
            documentos.formato_codigo,
            documentos.estado,
            count(*) AS documentos
           FROM public.documentos
          GROUP BY documentos.negocio_id, documentos.formato_codigo, documentos.estado
        )
 SELECT negocio_id,
    formato_codigo,
    estado,
    documentos,
    round(((100.0 * sum(documentos) FILTER (WHERE (estado = 'error'::public.estado_doc)) OVER (PARTITION BY negocio_id, formato_codigo)) / NULLIF(sum(documentos) OVER (PARTITION BY negocio_id, formato_codigo), (0)::numeric)), 1) AS pct_error_formato
   FROM por_estado
  ORDER BY negocio_id, formato_codigo, estado;



CREATE VIEW public.v_sesiones_atascadas AS
 SELECT id AS sesion_id,
    negocio_id,
    servicio_codigo,
    paso,
    estado,
    ultima_actividad,
    (now() - ultima_actividad) AS antiguedad
   FROM public.sesiones s
  WHERE (cerrada_en IS NULL)
  ORDER BY ultima_actividad;



ALTER TABLE ONLY public.alertas_enviadas
    ADD CONSTRAINT alertas_enviadas_pkey PRIMARY KEY (id);



ALTER TABLE ONLY public.alias
    ADD CONSTRAINT alias_negocio_id_texto_norm_key UNIQUE (negocio_id, texto_norm);



ALTER TABLE ONLY public.alias
    ADD CONSTRAINT alias_pkey PRIMARY KEY (id);



ALTER TABLE ONLY public.conocimiento_pendiente
    ADD CONSTRAINT conocimiento_pendiente_negocio_id_pregunta_norm_key UNIQUE (negocio_id, pregunta_norm);



ALTER TABLE ONLY public.conocimiento_pendiente
    ADD CONSTRAINT conocimiento_pendiente_pkey PRIMARY KEY (id);



ALTER TABLE ONLY public.conocimiento
    ADD CONSTRAINT conocimiento_pkey PRIMARY KEY (id);



ALTER TABLE ONLY public.conteos_inventario
    ADD CONSTRAINT conteos_inventario_negocio_id_producto_id_fecha_key UNIQUE (negocio_id, producto_id, fecha);



ALTER TABLE ONLY public.conteos_inventario
    ADD CONSTRAINT conteos_inventario_pkey PRIMARY KEY (id);



ALTER TABLE ONLY public.cotizaciones
    ADD CONSTRAINT cotizaciones_pkey PRIMARY KEY (id);



ALTER TABLE ONLY public.cotizaciones
    ADD CONSTRAINT cotizaciones_token_key UNIQUE (token);



ALTER TABLE ONLY public.documentos
    ADD CONSTRAINT documentos_negocio_id_hash_key UNIQUE (negocio_id, hash);



ALTER TABLE ONLY public.documentos
    ADD CONSTRAINT documentos_pkey PRIMARY KEY (id);



ALTER TABLE ONLY public.ejecuciones
    ADD CONSTRAINT ejecuciones_pkey PRIMARY KEY (id);



ALTER TABLE ONLY public.facturas
    ADD CONSTRAINT facturas_documento_id_key UNIQUE (documento_id);



ALTER TABLE ONLY public.facturas
    ADD CONSTRAINT facturas_pkey PRIMARY KEY (id);



ALTER TABLE ONLY public.fallas
    ADD CONSTRAINT fallas_pkey PRIMARY KEY (id);



ALTER TABLE ONLY public.formatos_documento
    ADD CONSTRAINT formatos_documento_pkey PRIMARY KEY (codigo);



ALTER TABLE ONLY public.identidades
    ADD CONSTRAINT identidades_canal_id_externo_key UNIQUE (canal, id_externo);



ALTER TABLE ONLY public.identidades
    ADD CONSTRAINT identidades_pkey PRIMARY KEY (id);



ALTER TABLE ONLY public.intenciones
    ADD CONSTRAINT intenciones_pkey PRIMARY KEY (codigo);



ALTER TABLE ONLY public.metricas_resultado
    ADD CONSTRAINT metricas_resultado_pkey PRIMARY KEY (regla);



ALTER TABLE ONLY public.modulos
    ADD CONSTRAINT modulos_pkey PRIMARY KEY (codigo);



ALTER TABLE ONLY public.movimientos
    ADD CONSTRAINT movimientos_pkey PRIMARY KEY (id);



ALTER TABLE ONLY public.negocios
    ADD CONSTRAINT negocios_pkey PRIMARY KEY (id);



ALTER TABLE ONLY public.pagos
    ADD CONSTRAINT pagos_pkey PRIMARY KEY (id);



ALTER TABLE ONLY public.plantillas
    ADD CONSTRAINT plantillas_pkey PRIMARY KEY (clave);



ALTER TABLE ONLY public.portal_tokens
    ADD CONSTRAINT portal_tokens_hash_key UNIQUE (hash);



ALTER TABLE ONLY public.portal_tokens
    ADD CONSTRAINT portal_tokens_pkey PRIMARY KEY (id);



ALTER TABLE ONLY public.productos
    ADD CONSTRAINT productos_pkey PRIMARY KEY (id);



ALTER TABLE ONLY public.prompts
    ADD CONSTRAINT prompts_pkey PRIMARY KEY (id);



ALTER TABLE ONLY public.prompts_tecnicos
    ADD CONSTRAINT prompts_tecnicos_pkey PRIMARY KEY (clave);



ALTER TABLE ONLY public.recomendaciones
    ADD CONSTRAINT recomendaciones_pkey PRIMARY KEY (id);



ALTER TABLE ONLY public.schema_migraciones
    ADD CONSTRAINT schema_migraciones_pkey PRIMARY KEY (archivo);



ALTER TABLE ONLY public.servicios_entradas
    ADD CONSTRAINT servicios_entradas_pkey PRIMARY KEY (servicio_codigo, formato_codigo);



ALTER TABLE ONLY public.servicios
    ADD CONSTRAINT servicios_pkey PRIMARY KEY (codigo);



ALTER TABLE ONLY public.sesiones
    ADD CONSTRAINT sesiones_pkey PRIMARY KEY (id);



ALTER TABLE ONLY public.sinonimos_columna
    ADD CONSTRAINT sinonimos_columna_pkey PRIMARY KEY (canonica, patron);



ALTER TABLE ONLY public.snapshots_negocio
    ADD CONSTRAINT snapshots_negocio_pkey PRIMARY KEY (id);



ALTER TABLE ONLY public.terceros
    ADD CONSTRAINT terceros_pkey PRIMARY KEY (id);



ALTER TABLE ONLY public.tipos_negocio
    ADD CONSTRAINT tipos_negocio_pkey PRIMARY KEY (codigo);



ALTER TABLE ONLY public.snapshots_negocio
    ADD CONSTRAINT uq_snapshot_dia UNIQUE (negocio_id, fecha);



ALTER TABLE ONLY public.usuarios
    ADD CONSTRAINT usuarios_pkey PRIMARY KEY (id);



ALTER TABLE ONLY public.usuarios
    ADD CONSTRAINT usuarios_telegram_user_id_key UNIQUE (telegram_user_id);



CREATE INDEX idx_alertas_cooldown ON public.alertas_enviadas USING btree (negocio_id, regla, clave_objeto, enviada_en DESC);



CREATE INDEX idx_alias_pendientes ON public.alias USING btree (negocio_id) WHERE (producto_id IS NULL);



CREATE INDEX idx_alias_texto_trgm ON public.alias USING gin (texto_norm public.gin_trgm_ops);



CREATE INDEX idx_conocimiento_negocio ON public.conocimiento USING btree (negocio_id, tipo);



CREATE INDEX idx_conocimiento_texto_trgm ON public.conocimiento USING gin (public.norm_texto(((titulo || ' '::text) || COALESCE(contenido, ''::text))) public.gin_trgm_ops);



CREATE INDEX idx_conteos_prod ON public.conteos_inventario USING btree (negocio_id, producto_id, fecha DESC);



CREATE INDEX idx_cotizaciones_negocio ON public.cotizaciones USING btree (negocio_id, creado_en DESC);



CREATE INDEX idx_documentos_sesion ON public.documentos USING btree (sesion_id);



CREATE INDEX idx_ejec_colgadas ON public.ejecuciones USING btree (inicio) WHERE (estado = ANY (ARRAY['preparando'::public.estado_ejec, 'procesando'::public.estado_ejec, 'validando'::public.estado_ejec]));



CREATE INDEX idx_ejec_negocio ON public.ejecuciones USING btree (negocio_id, inicio);



CREATE INDEX idx_facturas_abiertas ON public.facturas USING btree (negocio_id, vencimiento) WHERE (saldo > (0)::numeric);



CREATE INDEX idx_fallas_recientes ON public.fallas USING btree (creada_en);



CREATE INDEX idx_identidades_usuario ON public.identidades USING btree (usuario_id);



CREATE INDEX idx_mov_documento ON public.movimientos USING btree (documento_id);



CREATE INDEX idx_mov_negocio_fecha ON public.movimientos USING btree (negocio_id, fecha);



CREATE INDEX idx_mov_producto ON public.movimientos USING btree (producto_id);



CREATE INDEX idx_mov_tercero ON public.movimientos USING btree (tercero_id);



CREATE INDEX idx_pagos_factura ON public.pagos USING btree (factura_id);



CREATE INDEX idx_portal_tokens_vivos ON public.portal_tokens USING btree (expira_en) WHERE (usado_en IS NULL);



CREATE INDEX idx_productos_negocio ON public.productos USING btree (negocio_id);



CREATE INDEX idx_productos_nombre_trgm ON public.productos USING gin (nombre_canonico public.gin_trgm_ops);



CREATE INDEX idx_recomendaciones_negocio ON public.recomendaciones USING btree (negocio_id, estado, detectada_en DESC);



CREATE INDEX idx_sesiones_actividad ON public.sesiones USING btree (ultima_actividad) WHERE (cerrada_en IS NULL);



CREATE INDEX idx_sesiones_usuario ON public.sesiones USING btree (usuario_id) WHERE (cerrada_en IS NULL);



CREATE INDEX idx_snapshots_negocio_fecha ON public.snapshots_negocio USING btree (negocio_id, fecha DESC);



CREATE UNIQUE INDEX idx_terceros_nit ON public.terceros USING btree (negocio_id, nit) WHERE (nit IS NOT NULL);



CREATE UNIQUE INDEX idx_terceros_nombre ON public.terceros USING btree (negocio_id, public.norm_texto(nombre)) WHERE (nit IS NULL);



CREATE UNIQUE INDEX uq_conocimiento_clave ON public.conocimiento USING btree (negocio_id, tipo, clave) WHERE (clave IS NOT NULL);



CREATE UNIQUE INDEX uq_formato_huella ON public.formatos_documento USING btree (huella) WHERE (huella IS NOT NULL);



CREATE UNIQUE INDEX uq_param_global ON public.parametros USING btree (clave) WHERE (negocio_id IS NULL);



CREATE UNIQUE INDEX uq_param_negocio ON public.parametros USING btree (negocio_id, clave) WHERE (negocio_id IS NOT NULL);



CREATE UNIQUE INDEX uq_producto_barras ON public.productos USING btree (negocio_id, codigo_barras) WHERE (codigo_barras IS NOT NULL);



CREATE UNIQUE INDEX uq_prompt_activo ON public.prompts USING btree (servicio_codigo) WHERE activo;



CREATE UNIQUE INDEX uq_recomendacion_abierta ON public.recomendaciones USING btree (negocio_id, regla, clave_objeto) WHERE (estado = ANY (ARRAY['nueva'::text, 'vigente'::text]));



CREATE TRIGGER trg_movimientos_limite_plan BEFORE INSERT ON public.movimientos FOR EACH ROW EXECUTE FUNCTION public.movimientos_limite_plan();



ALTER TABLE ONLY public.alertas_enviadas
    ADD CONSTRAINT alertas_enviadas_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);



ALTER TABLE ONLY public.alias
    ADD CONSTRAINT alias_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);



ALTER TABLE ONLY public.alias
    ADD CONSTRAINT alias_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES public.productos(id);



ALTER TABLE ONLY public.conocimiento
    ADD CONSTRAINT conocimiento_actualizado_por_fkey FOREIGN KEY (actualizado_por) REFERENCES public.usuarios(id);



ALTER TABLE ONLY public.conocimiento
    ADD CONSTRAINT conocimiento_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);



ALTER TABLE ONLY public.conocimiento_pendiente
    ADD CONSTRAINT conocimiento_pendiente_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);



ALTER TABLE ONLY public.conocimiento_pendiente
    ADD CONSTRAINT conocimiento_pendiente_resuelto_por_fkey FOREIGN KEY (resuelto_por) REFERENCES public.conocimiento(id);



ALTER TABLE ONLY public.conteos_inventario
    ADD CONSTRAINT conteos_inventario_documento_id_fkey FOREIGN KEY (documento_id) REFERENCES public.documentos(id);



ALTER TABLE ONLY public.conteos_inventario
    ADD CONSTRAINT conteos_inventario_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);



ALTER TABLE ONLY public.conteos_inventario
    ADD CONSTRAINT conteos_inventario_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES public.productos(id);



ALTER TABLE ONLY public.cotizaciones
    ADD CONSTRAINT cotizaciones_creado_por_fkey FOREIGN KEY (creado_por) REFERENCES public.usuarios(id);



ALTER TABLE ONLY public.cotizaciones
    ADD CONSTRAINT cotizaciones_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);



ALTER TABLE ONLY public.documentos
    ADD CONSTRAINT documentos_formato_codigo_fkey FOREIGN KEY (formato_codigo) REFERENCES public.formatos_documento(codigo);



ALTER TABLE ONLY public.documentos
    ADD CONSTRAINT documentos_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);



ALTER TABLE ONLY public.documentos
    ADD CONSTRAINT documentos_sesion_id_fkey FOREIGN KEY (sesion_id) REFERENCES public.sesiones(id);



ALTER TABLE ONLY public.ejecuciones
    ADD CONSTRAINT ejecuciones_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);



ALTER TABLE ONLY public.ejecuciones
    ADD CONSTRAINT ejecuciones_servicio_codigo_fkey FOREIGN KEY (servicio_codigo) REFERENCES public.servicios(codigo);



ALTER TABLE ONLY public.ejecuciones
    ADD CONSTRAINT ejecuciones_sesion_id_fkey FOREIGN KEY (sesion_id) REFERENCES public.sesiones(id);



ALTER TABLE ONLY public.facturas
    ADD CONSTRAINT facturas_documento_id_fkey FOREIGN KEY (documento_id) REFERENCES public.documentos(id);



ALTER TABLE ONLY public.facturas
    ADD CONSTRAINT facturas_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);



ALTER TABLE ONLY public.facturas
    ADD CONSTRAINT facturas_tercero_id_fkey FOREIGN KEY (tercero_id) REFERENCES public.terceros(id);



ALTER TABLE ONLY public.fallas
    ADD CONSTRAINT fallas_ejecucion_id_fkey FOREIGN KEY (ejecucion_id) REFERENCES public.ejecuciones(id);



ALTER TABLE ONLY public.fallas
    ADD CONSTRAINT fallas_sesion_id_fkey FOREIGN KEY (sesion_id) REFERENCES public.sesiones(id);



ALTER TABLE ONLY public.identidades
    ADD CONSTRAINT identidades_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.usuarios(id) ON DELETE CASCADE;



ALTER TABLE ONLY public.movimientos
    ADD CONSTRAINT movimientos_alias_id_fkey FOREIGN KEY (alias_id) REFERENCES public.alias(id);



ALTER TABLE ONLY public.movimientos
    ADD CONSTRAINT movimientos_documento_id_fkey FOREIGN KEY (documento_id) REFERENCES public.documentos(id);



ALTER TABLE ONLY public.movimientos
    ADD CONSTRAINT movimientos_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);



ALTER TABLE ONLY public.movimientos
    ADD CONSTRAINT movimientos_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES public.productos(id);



ALTER TABLE ONLY public.movimientos
    ADD CONSTRAINT movimientos_tercero_id_fkey FOREIGN KEY (tercero_id) REFERENCES public.terceros(id);



ALTER TABLE ONLY public.pagos
    ADD CONSTRAINT pagos_factura_id_fkey FOREIGN KEY (factura_id) REFERENCES public.facturas(id);



ALTER TABLE ONLY public.pagos
    ADD CONSTRAINT pagos_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.usuarios(id);



ALTER TABLE ONLY public.parametros
    ADD CONSTRAINT parametros_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);



ALTER TABLE ONLY public.portal_tokens
    ADD CONSTRAINT portal_tokens_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.usuarios(id) ON DELETE CASCADE;



ALTER TABLE ONLY public.productos
    ADD CONSTRAINT productos_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);



ALTER TABLE ONLY public.prompts
    ADD CONSTRAINT prompts_servicio_codigo_fkey FOREIGN KEY (servicio_codigo) REFERENCES public.servicios(codigo);



ALTER TABLE ONLY public.recomendaciones
    ADD CONSTRAINT recomendaciones_ejecucion_id_fkey FOREIGN KEY (ejecucion_id) REFERENCES public.ejecuciones(id);



ALTER TABLE ONLY public.recomendaciones
    ADD CONSTRAINT recomendaciones_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);



ALTER TABLE ONLY public.servicios_entradas
    ADD CONSTRAINT servicios_entradas_formato_codigo_fkey FOREIGN KEY (formato_codigo) REFERENCES public.formatos_documento(codigo);



ALTER TABLE ONLY public.servicios_entradas
    ADD CONSTRAINT servicios_entradas_servicio_codigo_fkey FOREIGN KEY (servicio_codigo) REFERENCES public.servicios(codigo);



ALTER TABLE ONLY public.servicios
    ADD CONSTRAINT servicios_modulo_codigo_fkey FOREIGN KEY (modulo_codigo) REFERENCES public.modulos(codigo);



ALTER TABLE ONLY public.sesiones
    ADD CONSTRAINT sesiones_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);



ALTER TABLE ONLY public.sesiones
    ADD CONSTRAINT sesiones_servicio_codigo_fkey FOREIGN KEY (servicio_codigo) REFERENCES public.servicios(codigo);



ALTER TABLE ONLY public.sesiones
    ADD CONSTRAINT sesiones_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.usuarios(id);



ALTER TABLE ONLY public.snapshots_negocio
    ADD CONSTRAINT snapshots_negocio_ejecucion_id_fkey FOREIGN KEY (ejecucion_id) REFERENCES public.ejecuciones(id);



ALTER TABLE ONLY public.snapshots_negocio
    ADD CONSTRAINT snapshots_negocio_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);



ALTER TABLE ONLY public.terceros
    ADD CONSTRAINT terceros_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);



ALTER TABLE ONLY public.usuarios
    ADD CONSTRAINT usuarios_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);



GRANT USAGE ON SCHEMA public TO portal_anon;
GRANT USAGE ON SCHEMA public TO portal_usuario;



REVOKE ALL ON FUNCTION public.admin_reporte(p_cmd text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.alertas_evaluar() FROM PUBLIC;



REVOKE ALL ON FUNCTION public.alias_pendientes(p_negocio_id bigint, p_limite integer) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.b64url(p bytea) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.barra_10(p_valor numeric) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.canal_de_chat(p_chat_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.carga_arrancar(p_sesion_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.carga_evaluar(p_sesion_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.carga_hay_con_que(p_sesion_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.carga_panel(p_sesion_id bigint, p_modo text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.carga_panel_registrar(p_sesion_id bigint, p_mensaje_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.carga_registrar_fallo(p_sesion_id bigint, p_nombre text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.carga_resumen(p_sesion_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.cartera_facturar_dian(p_documento_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.cartera_refacturar(p_negocio_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.chat_de_usuario(p_usuario_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.cifra_norm(p_num text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.cifra_variantes(p_num text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.conocimiento_buscar(p_negocio_id bigint, p_texto text, p_limite integer, p_umbral numeric) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.conocimiento_guardar(p_negocio_id bigint, p_tipo text, p_titulo text, p_contenido text, p_clave text, p_datos jsonb, p_origen text, p_usuario_id bigint, p_pendiente_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.conocimiento_pendiente_registrar(p_negocio_id bigint, p_pregunta text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.consulta_iniciar(p_usuario_id bigint, p_negocio_id bigint, p_chat_id bigint, p_pregunta text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.contexto_negocio_recuperar(p_negocio_id bigint, p_contexto jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ejecucion_cerrar(p_ejecucion_id bigint, p_estado text, p_resultado jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ejecucion_preparar(p_ejecucion_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.esc_html(p_texto text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.extensiones_aceptadas() FROM PUBLIC;



REVOKE ALL ON FUNCTION public.fmt_decimal(p_num numeric) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.hallazgos_comparativo(p_negocio_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.hallazgos_compras(p_negocio_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.hallazgos_compras(p_negocio_id bigint, p_contexto jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.hallazgos_generar(p_negocio_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.hallazgos_generar(p_negocio_id bigint, p_contexto jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.informe_base_bloque(p_hallazgos jsonb, p_servicio text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.informe_estructura_seca(p_hallazgos jsonb, p_servicio text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.informe_render(p_estructura jsonb, p_hallazgos jsonb, p_servicio text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.informe_salud_bloque(p_salud jsonb, p_servicio text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.informes_periodicos_disparar() FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ingesta_cargar_inventario(p_documento_id bigint, p_filas jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ingesta_cargar_tabular(p_documento_id bigint, p_filas jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ingesta_cargar_tabular_detalle(p_documento_id bigint, p_filas jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ingesta_es_agregado(p_columnas jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ingesta_fecha(p_valor jsonb, p_formato text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ingesta_huella(p_columnas text[]) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ingesta_identificar_tabular(p_documento_id bigint, p_columnas text[]) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ingesta_identificar_tabular(p_documento_id bigint, p_columnas text[], p_muestra jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ingesta_inferir_decimales(p_muestra jsonb, p_columnas jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ingesta_inferir_formato_fecha(p_muestra jsonb, p_columna text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ingesta_inferir_mapeo_sql(p_documento_id bigint, p_columnas text[], p_muestra jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ingesta_inferir_tipo(p_documento_id bigint, p_columnas text[]) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ingesta_marcar_error(p_documento_id bigint, p_error text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ingesta_num(p_valor jsonb, p_decimal text, p_miles text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ingesta_parsear_dian(p_documento_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ingesta_procesar_documento(p_documento_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ingesta_registrar_documento(p_sesion_id bigint, p_negocio_id bigint, p_nombre_archivo text, p_mime text, p_contenido bytea) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ingesta_registrar_formato_inferido(p_documento_id bigint, p_columnas text[], p_mapeo jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ingesta_registrar_formato_resuelto(p_documento_id bigint, p_columnas text[], p_mapeo jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ingesta_resolver_columnas(p_columnas text[]) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ingesta_resumen_documento(p_documento_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.ingesta_resumen_sesion(p_sesion_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.intencion_agregados(p_negocio_id bigint, p_metrica text, p_desde date, p_hasta date, p_producto bigint, p_proveedor text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.intencion_detectar(p_texto text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.intencion_resolver(p_negocio_id bigint, p_texto text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.jwt_firmar(p_payload jsonb, p_secreto text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.limpiar_marcado(p_texto text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.mantenimiento_ciclo() FROM PUBLIC;



REVOKE ALL ON FUNCTION public.match_confirmar_alias(p_alias_id bigint, p_producto_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.match_resolver_documento(p_documento_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.match_resolver_producto(p_negocio_id bigint, p_texto text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.mercado_compras_bienvenida(p_negocio_id bigint, p_chat_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.mes_es(p_fecha date) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.miles(p numeric) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.movimientos_limite_plan() FROM PUBLIC;



REVOKE ALL ON FUNCTION public.nit_dv(p_nit text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.norm_pregunta(p text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.norm_texto(p text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.pago_registrar(p_factura_id bigint, p_valor numeric, p_fecha date, p_medio text, p_origen text, p_usuario_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.parametro(p_negocio_id bigint, p_clave text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.pedido_sugerido(p_negocio_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.perfil_negocio(p_negocio_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.periodo_es(p_desde date, p_hasta date) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.periodo_resolver(p_texto text, p_defecto text, p_hasta date) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.plan_desde(p_negocio_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.plantilla_cuerpo(p_clave text, p_defecto text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.plantilla_cuerpo_srv(p_clave text, p_servicio text, p_defecto text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.portal_alias_confirmar(p_alias_id bigint, p_producto_id bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_alias_confirmar(p_alias_id bigint, p_producto_id bigint) TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_alias_pendientes(p_limite integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_alias_pendientes(p_limite integer) TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_cartera() FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_cartera() TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_claim(p_clave text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.portal_conocimiento(p_tipo text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_conocimiento(p_tipo text) TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_conocimiento_borrar(p_id bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_conocimiento_borrar(p_id bigint) TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_conocimiento_guardar(p_titulo text, p_tipo text, p_contenido text, p_clave text, p_datos jsonb, p_id bigint, p_pendiente_id bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_conocimiento_guardar(p_titulo text, p_tipo text, p_contenido text, p_clave text, p_datos jsonb, p_id bigint, p_pendiente_id bigint) TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_conteo_guardar(p_producto_id bigint, p_unidades numeric, p_fecha date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_conteo_guardar(p_producto_id bigint, p_unidades numeric, p_fecha date) TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_conteos(p_limite integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_conteos(p_limite integer) TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_cotizacion_guardar(p_items jsonb, p_cliente text, p_notas text, p_vigente_hasta date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_cotizacion_guardar(p_items jsonb, p_cliente text, p_notas text, p_vigente_hasta date) TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_cotizacion_publica(p_token text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_cotizacion_publica(p_token text) TO portal_anon;
GRANT ALL ON FUNCTION public.portal_cotizacion_publica(p_token text) TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_cotizacion_revocar(p_id bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_cotizacion_revocar(p_id bigint) TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_cotizaciones(p_limite integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_cotizaciones(p_limite integer) TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_documentos(p_limite integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_documentos(p_limite integer) TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_factura_guardar(p_tercero text, p_total numeric, p_vencimiento date, p_numero text, p_emision date, p_nit text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_factura_guardar(p_tercero text, p_total numeric, p_vencimiento date, p_numero text, p_emision date, p_nit text) TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_informe(p_id bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_informe(p_id bigint) TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_informes(p_limite integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_informes(p_limite integer) TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_mov_nombre(p_raw jsonb, p_mapeo jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.portal_movimientos(p_tipo text, p_limite integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_movimientos(p_tipo text, p_limite integer) TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_movimientos_resumen() FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_movimientos_resumen() TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_negocio() FROM PUBLIC;



REVOKE ALL ON FUNCTION public.portal_negocio_guardar(p_nit text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_negocio_guardar(p_nit text) TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_pago_registrar(p_factura_id bigint, p_valor numeric, p_fecha date, p_medio text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_pago_registrar(p_factura_id bigint, p_valor numeric, p_fecha date, p_medio text) TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_pedido() FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_pedido() TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_pendientes() FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_pendientes() TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_perfil() FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_perfil() TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_productos() FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_productos() TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_recomendacion_accion(p_id bigint, p_accion text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_recomendacion_accion(p_id bigint, p_accion text) TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_recomendaciones(p_limite integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_recomendaciones(p_limite integer) TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_sesion_abrir(p_token text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_sesion_abrir(p_token text) TO portal_anon;



REVOKE ALL ON FUNCTION public.portal_snapshots(p_limite integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.portal_snapshots(p_limite integer) TO portal_usuario;



REVOKE ALL ON FUNCTION public.portal_token_crear(p_usuario_id bigint, p_minutos integer) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.recomendacion_accion(p_reco_id bigint, p_negocio_id bigint, p_accion text, p_usuario_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.recomendacion_marcar_cierre(p_reco_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.recomendacion_metrica_valor(p_negocio_id bigint, p_clave text, p_metrica text, p_desde date) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.recomendacion_objeto_evaluable(p_negocio_id bigint, p_clave text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.recomendaciones_medir(p_negocio_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.recomendaciones_negocio(p_negocio_id bigint, p_registro boolean) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.recomendaciones_registrar(p_negocio_id bigint, p_ejecucion_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.recomendaciones_vigentes(p_negocio_id bigint, p_limite integer) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.resolver_plantilla(p_clave text, p_vars jsonb, p_teclado jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.router_arranque_servicio(p_negocio_id bigint, p_chat_id bigint, p_servicio text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.router_ctx(p_evento jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.router_h_admin(p_ctx jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.router_h_comandos(p_ctx jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.router_h_intake(p_ctx jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.router_h_recibiendo(p_ctx jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.router_h_sin_sesion(p_ctx jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.router_marcar_editables(p_res jsonb, p_evento jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.router_plan(p_negocio_id bigint, p_chat_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.router_portal(p_usuario_id bigint, p_chat_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.router_procesar_mensaje(p_evento jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.router_respuesta(p_chat bigint, p_plantilla text, p_vars jsonb, p_teclado jsonb, p_acciones jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.salud_negocio(p_negocio_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.semaforo(p_valor numeric) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.snapshot_anterior(p_negocio_id bigint, p_antes_de date) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.snapshot_tomar(p_negocio_id bigint, p_origen text, p_ejecucion_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.snapshot_umbrales(p_negocio_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.snapshot_version() FROM PUBLIC;



REVOKE ALL ON FUNCTION public.snapshots_backfill() FROM PUBLIC;



REVOKE ALL ON FUNCTION public.teclado_consentimiento(p_contexto text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.teclado_intake() FROM PUBLIC;



REVOKE ALL ON FUNCTION public.teclado_markup(p_teclado jsonb, p_vars jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.teclado_modulo(p_codigo text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.teclado_modulos() FROM PUBLIC;



REVOKE ALL ON FUNCTION public.teclado_recomendacion(p_reco_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.teclado_recomendaciones(p_negocio_id bigint) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.teclado_tipos_negocio() FROM PUBLIC;



REVOKE ALL ON FUNCTION public.tercero_obtener(p_negocio_id bigint, p_nit text, p_nombre text) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.unidades_es(p_n numeric) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.usuario_de_canal(p_canal text, p_evento jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.usuario_de_telegram(p_evento jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.validar_cifras(p_texto text, p_hallazgos jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.wa_payload(p_para text, p_texto text, p_markup jsonb) FROM PUBLIC;



REVOKE ALL ON FUNCTION public.wa_texto(p_html text) FROM PUBLIC;



ALTER DEFAULT PRIVILEGES FOR ROLE chasqui REVOKE ALL ON FUNCTIONS FROM PUBLIC;




