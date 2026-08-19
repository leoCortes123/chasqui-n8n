CREATE OR REPLACE FUNCTION public.router_h_admin(p_ctx jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
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
$function$
