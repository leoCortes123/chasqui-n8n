CREATE OR REPLACE FUNCTION public.jwt_firmar(p_payload jsonb, p_secreto text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT cuerpo || '.' || b64url(hmac(cuerpo, p_secreto, 'sha256'))
    FROM (SELECT b64url(convert_to('{"alg":"HS256","typ":"JWT"}', 'utf8')) || '.' ||
                 b64url(convert_to(p_payload::text, 'utf8')) AS cuerpo) s;
$function$
