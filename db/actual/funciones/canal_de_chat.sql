CREATE OR REPLACE FUNCTION public.canal_de_chat(p_chat_id bigint)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
    SELECT coalesce(
        (SELECT canal FROM identidades
          WHERE datos ->> 'chat_id' = p_chat_id::text
          ORDER BY vista_en DESC LIMIT 1),
        'telegram');
$function$
