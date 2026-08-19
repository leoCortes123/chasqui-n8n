CREATE OR REPLACE FUNCTION public.intencion_detectar(p_texto text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
    WITH q AS (SELECT norm_texto(coalesce(p_texto, '')) AS t)
    SELECT i.codigo
    FROM intenciones i, q,
         LATERAL (SELECT count(*) AS n FROM unnest(i.patrones) pa
                   WHERE q.t LIKE '%' || norm_texto(pa) || '%') m
    WHERE i.activo AND m.n > 0
    ORDER BY m.n DESC, i.orden
    LIMIT 1;
$function$
