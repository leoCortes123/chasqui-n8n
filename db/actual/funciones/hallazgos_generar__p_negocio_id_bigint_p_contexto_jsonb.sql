CREATE OR REPLACE FUNCTION public.hallazgos_generar(p_negocio_id bigint, p_contexto jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT hallazgos_generar(p_negocio_id);
$function$
