CREATE OR REPLACE FUNCTION public.recomendaciones_vigentes(p_negocio_id bigint, p_limite integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'id', id, 'regla', regla, 'clave_objeto', clave_objeto,
             'icono', icono,
             'titulo', titulo, 'problema', problema, 'impacto', impacto,
             'impacto_mes', impacto_mes, 'impacto_tipo', impacto_tipo,
             'prioridad', prioridad, 'opciones', opciones,
             'datos', coalesce(datos, '{}'::jsonb),
             'origen_stock', origen_stock, 'estado', estado,
             'detectada_en', detectada_en, 'veces_vista', veces_vista,
             -- Cuántos periodos lleva sin resolverse. Es la diferencia entre
             -- "te lo digo por primera vez" y "van cuatro veces".
             'dias_abierta', (current_date - detectada_en::date))
             ORDER BY CASE prioridad WHEN 'alta' THEN 1 WHEN 'media' THEN 2 ELSE 3 END,
                      impacto_mes DESC), '[]'::jsonb)
    FROM (SELECT * FROM recomendaciones
           WHERE negocio_id = p_negocio_id AND estado IN ('nueva','vigente')
           ORDER BY CASE prioridad WHEN 'alta' THEN 1 WHEN 'media' THEN 2 ELSE 3 END,
                    impacto_mes DESC
           LIMIT p_limite) r;
$function$
