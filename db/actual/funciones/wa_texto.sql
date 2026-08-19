CREATE OR REPLACE FUNCTION public.wa_texto(p_html text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT replace(replace(replace(
             regexp_replace(
             regexp_replace(
             regexp_replace(
             regexp_replace(
             regexp_replace(
             regexp_replace(
             regexp_replace(coalesce(p_html, ''),
               '</?(b|strong)>',        '*',        'gi'),
               '</?(i|em)>',            '_',        'gi'),
               '</?(s|strike|del)>',    '~',        'gi'),
               '</?(code|pre)>',        '```',      'gi'),
               '<a[^>]*href="([^"]*)"[^>]*>([^<]*)</a>', '\2 (\1)', 'gi'),
               '<br[^>]*>',             E'\n',      'gi'),
               '<[^>]+>',               '',         'g'),
           '&lt;', '<'), '&gt;', '>'), '&amp;', '&');
$function$
