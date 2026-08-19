CREATE OR REPLACE FUNCTION public.router_procesar_mensaje(p_evento jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
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
$function$
