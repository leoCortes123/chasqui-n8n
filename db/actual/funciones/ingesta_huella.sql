CREATE OR REPLACE FUNCTION public.ingesta_huella(p_columnas text[])
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT md5(string_agg(c, '|' ORDER BY c))
    FROM (SELECT DISTINCT norm_texto(unnest) AS c
          FROM unnest(p_columnas)
          WHERE btrim(coalesce(unnest,'')) <> '') s;
$function$
