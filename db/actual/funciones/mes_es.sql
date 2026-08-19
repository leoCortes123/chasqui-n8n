CREATE OR REPLACE FUNCTION public.mes_es(p_fecha date)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT (ARRAY['enero','febrero','marzo','abril','mayo','junio','julio',
                  'agosto','septiembre','octubre','noviembre','diciembre']
           )[extract(month from p_fecha)::int];
$function$
