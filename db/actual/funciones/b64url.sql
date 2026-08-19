CREATE OR REPLACE FUNCTION public.b64url(p bytea)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT rtrim(translate(replace(encode(p, 'base64'), E'\n', ''), '+/', '-_'), '=');
$function$
