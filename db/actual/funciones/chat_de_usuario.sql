CREATE OR REPLACE FUNCTION public.chat_de_usuario(p_usuario_id bigint)
 RETURNS bigint
 LANGUAGE sql
 STABLE
AS $function$
    SELECT coalesce(
        (SELECT (datos ->> 'chat_id')::bigint FROM identidades
          WHERE usuario_id = p_usuario_id AND datos ? 'chat_id'
          ORDER BY vista_en DESC LIMIT 1),
        (SELECT telegram_chat_id FROM usuarios WHERE id = p_usuario_id));
$function$
