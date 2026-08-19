CREATE OR REPLACE FUNCTION public.parametro(p_negocio_id bigint, p_clave text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT valor FROM parametros
    WHERE clave = p_clave
      AND (negocio_id = p_negocio_id OR negocio_id IS NULL)
    ORDER BY negocio_id NULLS LAST
    LIMIT 1;
$function$
