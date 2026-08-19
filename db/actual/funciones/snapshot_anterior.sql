CREATE OR REPLACE FUNCTION public.snapshot_anterior(p_negocio_id bigint, p_antes_de date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT jsonb_build_object(
             'id', id, 'fecha', fecha, 'version', version,
             'periodo_desde', lower(periodo), 'periodo_hasta', upper(periodo),
             'origen', origen, 'salud', salud, 'metricas', metricas)
    FROM snapshots_negocio
    WHERE negocio_id = p_negocio_id AND fecha < p_antes_de
    ORDER BY fecha DESC
    LIMIT 1;
$function$
