CREATE OR REPLACE FUNCTION public.ingesta_resolver_columnas(p_columnas text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_res     jsonb := '{}'::jsonb;
    v_usadas  text[] := '{}';
    r         record;
BEGIN
    FOR r IN
        WITH pares AS (
            SELECT s.canonica, c.col, c.ord, min(s.prioridad) AS prioridad
            FROM unnest(p_columnas) WITH ORDINALITY AS c(col, ord)
            JOIN sinonimos_columna s ON norm_texto(c.col) ~ s.patron
            WHERE btrim(coalesce(c.col,'')) <> ''
            GROUP BY s.canonica, c.col, c.ord
        )
        SELECT canonica, col FROM pares
        -- prioridad manda; a igual prioridad gana la columna que aparece antes
        -- en el archivo, que es un desempate estable y no depende del planner.
        ORDER BY prioridad, ord, canonica
    LOOP
        IF NOT (v_res ? r.canonica) AND NOT (r.col = ANY(v_usadas)) THEN
            v_res    := v_res || jsonb_build_object(r.canonica, r.col);
            v_usadas := v_usadas || r.col;
        END IF;
    END LOOP;

    RETURN v_res;
END;
$function$
