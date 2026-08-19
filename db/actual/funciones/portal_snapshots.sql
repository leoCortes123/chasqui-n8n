CREATE OR REPLACE FUNCTION public.portal_snapshots(p_limite integer DEFAULT 24)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    RETURN coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'fecha', fecha,
               'periodo_desde', lower(periodo), 'periodo_hasta', upper(periodo),
               'origen', origen,
               'parcial', coalesce((metricas -> 'parcial')::boolean, false),
               'salud', salud,
               'ventas',  metricas #> '{totales,ventas}',
               'compras', metricas #> '{totales,compras}',
               'productos', metricas #> '{productos,total}',
               'margen_promedio_pct', metricas #> '{productos,margen_promedio_pct}')
               ORDER BY fecha DESC)
      FROM (SELECT * FROM snapshots_negocio
             WHERE negocio_id = v_negocio
             ORDER BY fecha DESC LIMIT p_limite) s), '[]'::jsonb);
END;
$function$
