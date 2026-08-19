CREATE OR REPLACE FUNCTION public.router_h_comandos(p_ctx jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
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
$function$
