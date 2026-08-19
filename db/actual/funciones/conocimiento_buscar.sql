CREATE OR REPLACE FUNCTION public.conocimiento_buscar(p_negocio_id bigint, p_texto text, p_limite integer DEFAULT 8, p_umbral numeric DEFAULT 0.12)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    WITH q AS (SELECT norm_texto(p_texto) AS t)
    SELECT coalesce(jsonb_agg(x ORDER BY x -> 'parecido' DESC), '[]'::jsonb)
    FROM (
        SELECT jsonb_build_object(
                 'id', c.id, 'tipo', c.tipo, 'clave', c.clave,
                 'titulo', c.titulo, 'contenido', c.contenido, 'datos', c.datos,
                 'parecido', round(greatest(
                     similarity(norm_texto(c.titulo), q.t),
                     similarity(norm_texto(coalesce(c.contenido, '')), q.t))::numeric, 3)
               ) AS x
        FROM conocimiento c, q
        WHERE c.negocio_id = p_negocio_id
          AND c.vigente_desde <= current_date
          AND (c.vigente_hasta IS NULL OR c.vigente_hasta >= current_date)
          AND (q.t = '' OR greatest(
                 similarity(norm_texto(c.titulo), q.t),
                 similarity(norm_texto(coalesce(c.contenido, '')), q.t)) >= p_umbral)
        ORDER BY greatest(
                   similarity(norm_texto(c.titulo), q.t),
                   similarity(norm_texto(coalesce(c.contenido, '')), q.t)) DESC,
                 c.actualizado_en DESC
        LIMIT greatest(p_limite, 1)
    ) s;
$function$
