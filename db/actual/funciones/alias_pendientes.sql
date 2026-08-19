CREATE OR REPLACE FUNCTION public.alias_pendientes(p_negocio_id bigint, p_limite integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'alias_id',   x.id,
             'texto',      x.texto_norm,
             'movimientos',x.movs,
             'dinero',     x.dinero,
             'candidato_id',     x.candidato_id,
             'candidato_nombre', x.candidato_nombre,
             'similitud',        x.similitud)
             ORDER BY x.dinero DESC, x.movs DESC), '[]'::jsonb)
    FROM (
        SELECT a.id, a.texto_norm,
               (SELECT count(*) FROM mov_visibles m
                 WHERE m.negocio_id = a.negocio_id AND m.producto_id IS NULL
                   AND (m.alias_id = a.id
                        OR norm_texto(m.raw ->> 'descripcion') = a.texto_norm
                        OR norm_texto(m.raw ->> 'producto')    = a.texto_norm)) AS movs,
               (SELECT round(coalesce(sum(m.valor_total), 0)) FROM mov_visibles m
                 WHERE m.negocio_id = a.negocio_id AND m.producto_id IS NULL
                   AND (m.alias_id = a.id
                        OR norm_texto(m.raw ->> 'descripcion') = a.texto_norm
                        OR norm_texto(m.raw ->> 'producto')    = a.texto_norm)) AS dinero,
               c.id AS candidato_id, c.nombre_canonico AS candidato_nombre,
               round(c.sim::numeric, 3) AS similitud
        FROM alias a
        LEFT JOIN LATERAL (
            SELECT p.id, p.nombre_canonico,
                   similarity(norm_texto(p.nombre_canonico), a.texto_norm) AS sim
            FROM productos p
            WHERE p.negocio_id = a.negocio_id
            ORDER BY sim DESC LIMIT 1
        ) c ON true
        WHERE a.negocio_id = p_negocio_id AND a.producto_id IS NULL
        ORDER BY 4 DESC NULLS LAST
        LIMIT p_limite
    ) x;
$function$
