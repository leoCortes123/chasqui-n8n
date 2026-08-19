CREATE OR REPLACE FUNCTION public.snapshot_umbrales(p_negocio_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT coalesce(jsonb_object_agg(clave, valor), '{}'::jsonb)
    FROM (SELECT DISTINCT ON (clave) clave, valor
          FROM parametros
          WHERE negocio_id = p_negocio_id OR negocio_id IS NULL
          ORDER BY clave, negocio_id NULLS LAST) t;
$function$
