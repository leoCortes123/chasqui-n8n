CREATE OR REPLACE FUNCTION public.fmt_decimal(p_num numeric)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT CASE WHEN p_num IS NULL THEN ''
      ELSE replace(regexp_replace(regexp_replace(p_num::text, '0+$', ''), '\.$', ''),
                   '.', ',') END;
$function$
