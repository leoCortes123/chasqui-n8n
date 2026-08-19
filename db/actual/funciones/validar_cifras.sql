CREATE OR REPLACE FUNCTION public.validar_cifras(p_texto text, p_hallazgos jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
    v_permitidos text[];
    v_num        text;
    v_inventadas text[] := '{}';
BEGIN
    -- Dos extracciones sobre el mismo texto, unidas:
    --
    --   `literal`  — la de siempre. Los hallazgos son JSON, así que sus valores
    --                numéricos vienen con punto decimal y sin separador de
    --                miles: basta normalizar los ceros de relleno. Se conserva
    --                tal cual para que lo permitido hoy siga permitido.
    --
    --   `humano`   — 055. Los hallazgos también traen TEXTO ya redactado por
    --                SQL ("para 142,3 días"), donde las cifras salieron de
    --                `fmt_decimal` y `miles` con formato colombiano. Cada una se
    --                expande a sus dos lecturas con la misma `cifra_variantes`
    --                que se le aplica al texto del modelo. Simetría: si las dos
    --                puntas se leen igual, un número bien copiado coincide.
    WITH literal AS (
        SELECT (regexp_matches(p_hallazgos::text, '\d+(?:\.\d+)?', 'g'))[1] AS n
    ),
    humano AS (
        SELECT (regexp_matches(p_hallazgos::text, '\d[\d.,]*', 'g'))[1] AS n
    )
    SELECT array_agg(DISTINCT v) INTO v_permitidos
    FROM (
        SELECT cifra_norm(n) AS v FROM literal
        UNION ALL
        SELECT v FROM humano, LATERAL unnest(cifra_variantes(humano.n)) AS v
    ) s
    WHERE v <> '';

    FOR v_num IN
        SELECT m[1] FROM regexp_matches(coalesce(p_texto, ''), '\d[\d.,]*', 'g') AS m
    LOOP
        -- Los números de menos de 3 dígitos se ignoran: un "3 productos" o un
        -- "80 %" no son cifras copiadas de ningún lado.
        CONTINUE WHEN length(regexp_replace(v_num, '\D', '', 'g')) < 3;
        IF NOT (cifra_variantes(v_num) && coalesce(v_permitidos, '{}')) THEN
            v_inventadas := array_append(v_inventadas, v_num);
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'ok', cardinality(v_inventadas) = 0,
        'inventadas', to_jsonb(v_inventadas));
END;
$function$
