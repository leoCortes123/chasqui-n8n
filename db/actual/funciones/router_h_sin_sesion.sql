CREATE OR REPLACE FUNCTION public.router_h_sin_sesion(p_ctx jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
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
$function$
