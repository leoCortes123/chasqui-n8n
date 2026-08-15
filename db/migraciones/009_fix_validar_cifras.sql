-- 009_fix_validar_cifras.sql — recorta la puntuación final del número antes
-- de comparar (evita falsos positivos como "10800." por el punto de la frase).
CREATE OR REPLACE FUNCTION validar_cifras(p_texto text, p_hallazgos jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_permitidos text[];
    v_num        text;
    v_inventadas text[] := '{}';
BEGIN
    SELECT array_agg(DISTINCT n) INTO v_permitidos
    FROM (
        SELECT regexp_replace((regexp_matches(p_hallazgos::text, '\d+(?:\.\d+)?', 'g'))[1],
                              '\.0+$', '') AS n
    ) s;

    FOR v_num IN
        SELECT regexp_replace(
                 regexp_replace(
                   regexp_replace(rtrim(m[1], '.,'), '[.,](?=\d{3}\b)', '', 'g'),
                   '\.0+$', ''),
                 '\.$', '')
        FROM regexp_matches(p_texto, '\d[\d.,]*', 'g') AS m
    LOOP
        IF length(regexp_replace(v_num, '\D', '', 'g')) >= 3
           AND NOT (v_num = ANY(v_permitidos)) THEN
            v_inventadas := array_append(v_inventadas, v_num);
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'ok', cardinality(v_inventadas) = 0,
        'inventadas', to_jsonb(v_inventadas)
    );
END;
$$;
