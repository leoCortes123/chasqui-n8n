CREATE OR REPLACE FUNCTION public.teclado_recomendaciones(p_negocio_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT coalesce(
             (SELECT jsonb_agg(jsonb_build_array(jsonb_build_object(
                       'texto', left(titulo, 40), 'dato', 'rec:ver:' || id))
                       ORDER BY orden)
              FROM (SELECT id, titulo,
                           row_number() OVER (
                             ORDER BY CASE prioridad WHEN 'alta' THEN 1
                                                     WHEN 'media' THEN 2 ELSE 3 END,
                                      impacto_mes DESC) AS orden
                    FROM recomendaciones
                    WHERE negocio_id = p_negocio_id AND estado IN ('nueva','vigente')
                    ORDER BY orden LIMIT 5) r),
             '[]'::jsonb)
           || jsonb_build_array(jsonb_build_array(jsonb_build_object(
                'texto', '⬅️ Volver', 'dato', '/ayuda')));
$function$
