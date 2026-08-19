CREATE OR REPLACE FUNCTION public.router_h_intake(p_ctx jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
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
$function$
