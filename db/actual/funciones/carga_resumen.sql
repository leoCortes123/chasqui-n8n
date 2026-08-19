CREATE OR REPLACE FUNCTION public.carga_resumen(p_sesion_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    WITH d AS (
        SELECT * FROM documentos WHERE sesion_id = p_sesion_id
    ),
    m AS (
        SELECT count(*) AS filas, min(fecha) AS desde, max(fecha) AS hasta
        FROM movimientos WHERE documento_id IN (SELECT id FROM d)
    ),
    f AS (
        SELECT coalesce(s.contexto -> 'descargas_fallidas', '[]'::jsonb) AS j
        FROM sesiones s WHERE s.id = p_sesion_id
    )
    SELECT jsonb_build_object(
        'no_bajados',  (SELECT jsonb_array_length(j) FROM f),
        'nombres_no_bajados',
                       (SELECT coalesce(string_agg(DISTINCT x, ', '), '')
                          FROM f, jsonb_array_elements_text(f.j) AS x),
        'archivos',   (SELECT count(*) FROM d WHERE estado = 'parseado'),
        'pendientes', (SELECT count(*) FROM d WHERE estado = 'pendiente'),
        'fallados',   (SELECT count(*) FROM d WHERE estado = 'error'),
        'nombres_fallados',
                      (SELECT coalesce(string_agg(nombre_archivo, ', '
                                                  ORDER BY id), '')
                         FROM (SELECT id, nombre_archivo FROM d
                                WHERE estado = 'error' ORDER BY id LIMIT 5) t),
        'movimientos', (SELECT filas FROM m),
        'desde',       (SELECT desde  FROM m),
        'hasta',       (SELECT hasta  FROM m),
        'periodo',     (SELECT coalesce(periodo_es(desde, hasta), '') FROM m),
        'ultimo_en',   (SELECT max(creado_en) FROM d)
    );
$function$
