CREATE OR REPLACE FUNCTION public.router_portal(p_usuario_id bigint, p_chat_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
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
$function$
