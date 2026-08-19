CREATE OR REPLACE FUNCTION public.router_marcar_editables(p_res jsonb, p_evento jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT CASE
      -- Sin mensaje que editar (llegó escrito, o es WhatsApp) no hay nada que
      -- hacer. Es el camino de siempre y tiene que salir intacto.
      WHEN nullif(p_evento ->> 'message_id', '') IS NULL
        OR jsonb_array_length(coalesce(p_res -> 'respuestas', '[]'::jsonb)) = 0
      THEN p_res
      ELSE jsonb_set(p_res, '{respuestas}', (
        SELECT jsonb_agg(
                 CASE WHEN coalesce(pl.reemplaza, false)
                      THEN e.r || jsonb_build_object('editar',
                             (p_evento ->> 'message_id')::bigint)
                      ELSE e.r END
                 ORDER BY e.ord)
        FROM jsonb_array_elements(p_res -> 'respuestas')
             WITH ORDINALITY AS e(r, ord)
        LEFT JOIN plantillas pl ON pl.clave = e.r ->> 'plantilla'))
    END;
$function$
