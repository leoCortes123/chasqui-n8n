CREATE OR REPLACE FUNCTION public.hallazgos_compras(p_negocio_id bigint, p_contexto jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT hallazgos_compras(p_negocio_id)
           || jsonb_build_object(
                'salud', salud_negocio(p_negocio_id),
                'recomendaciones', recomendaciones_negocio(p_negocio_id),
                'tipo_negocio', (SELECT coalesce(t.nombre, n.tipo)
                                 FROM negocios n
                                 LEFT JOIN tipos_negocio t ON t.codigo = n.tipo
                                 WHERE n.id = p_negocio_id));
$function$
