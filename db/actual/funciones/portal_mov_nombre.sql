CREATE OR REPLACE FUNCTION public.portal_mov_nombre(p_raw jsonb, p_mapeo jsonb)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT coalesce(p_raw ->> 'descripcion',
                    p_raw ->> 'producto',
                    p_raw ->> nullif(p_mapeo #>> '{columnas,producto}', ''));
$function$
