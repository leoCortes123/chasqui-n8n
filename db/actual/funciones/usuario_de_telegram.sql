CREATE OR REPLACE FUNCTION public.usuario_de_telegram(p_evento jsonb)
 RETURNS bigint
 LANGUAGE sql
AS $function$
    SELECT usuario_de_canal('telegram', p_evento);
$function$
