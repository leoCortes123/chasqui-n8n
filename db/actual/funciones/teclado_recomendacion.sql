CREATE OR REPLACE FUNCTION public.teclado_recomendacion(p_reco_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT jsonb_build_array(
             jsonb_build_array(jsonb_build_object(
               'texto', '✅ Ya lo hice', 'dato', 'rec:hice:' || r.id)),
             jsonb_build_array(jsonb_build_object(
               'texto', '⏭️ No aplica', 'dato', 'rec:no_aplica:' || r.id)))
           || CASE WHEN nullif(r.datos ->> 'precio_sugerido', '') IS NOT NULL
                   THEN jsonb_build_array(jsonb_build_array(jsonb_build_object(
                          'texto', '💲 Aplicar $' || miles((r.datos ->> 'precio_sugerido')::numeric),
                          'dato', 'rec:precio:' || r.id)))
                   ELSE '[]'::jsonb END
           || jsonb_build_array(jsonb_build_array(jsonb_build_object(
                'texto', '⬅️ Volver', 'dato', 'rec:list')))
    FROM recomendaciones r WHERE r.id = p_reco_id;
$function$
