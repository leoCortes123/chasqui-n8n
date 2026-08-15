-- 026_fix_cifras_miles.sql — validar_cifras entendía mal los separadores de miles.
--
-- Dos bugs, uno viejo y uno mío de la migración 025.
--
-- EL VIEJO (venía desde 009). En las expresiones regulares de Postgres `\b` NO
-- es un límite de palabra —eso es `\y`—, sino el carácter backspace. O sea que
-- este patrón nunca coincidió con nada:
--
--   regexp_replace('1.234.567', '[.,](?=\d{3}\b)', '', 'g')  ->  1.234.567
--   regexp_replace('1.234.567', '[.,](?=\d{3}\y)', '', 'g')  ->  1234567
--
-- Consecuencia: la normalización de miles era un no-op desde que se escribió.
-- Cada vez que el modelo escribía una cifra como se escribe en Colombia
-- ("10.800 pesos") no coincidía con el "10800" de los hallazgos, se marcaba como
-- inventada y se quemaba un reintento completo para acabar entregando el informe
-- seco. El propio comentario de 009 hablaba de arreglar "10800.", que sí
-- funcionaba: lo que arreglaba era el rtrim de la puntuación, no los miles.
--
-- EL MÍO (025). cifra_canonica recortaba los ceros finales de cualquier número
-- que tuviera un punto, y como los miles seguían sin quitarse, '1.000' terminaba
-- convertido en '1'. Peor que el original.
--
-- ARREGLO. El problema de fondo es que "1.234" es ambiguo: son mil doscientos
-- treinta y cuatro, o uno con 234 milésimas, según de dónde venga el texto. En
-- vez de adivinar, se comparan las DOS lecturas posibles y basta con que una
-- coincida. Un número realmente inventado no coincide con ninguna, que es lo que
-- esta validación tiene que atrapar; y un número bien copiado deja de costar un
-- reintento por una cuestión de tipografía.

DROP FUNCTION IF EXISTS cifra_canonica(text);

-- Quita los ceros de relleno de la parte decimal: 28.40 -> 28.4, 30.00 -> 30.
-- Solo si hay parte decimal: en un entero los ceros son la cifra.
CREATE FUNCTION cifra_norm(p_num text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN strpos(coalesce(p_num, ''), '.') = 0 THEN coalesce(p_num, '')
                ELSE regexp_replace(regexp_replace(p_num, '0+$', ''), '\.$', '') END;
$$;

-- Lecturas posibles de un número escrito por un humano (o por un modelo):
--   'miles'   -> todo separador es de miles:      1.234,56 -> 123456
--   'decimal' -> el ÚLTIMO separador es decimal:  1.234,56 -> 1234.56
-- Para '28,4' da {284, 28.4}; el 28.4 es el que coincide con los hallazgos.
CREATE FUNCTION cifra_variantes(p_num text) RETURNS text[] LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_t    text := rtrim(coalesce(p_num, ''), '.,');   -- puntuación de la frase
    v_pre  text;
    v_cola text;
    v_out  text[];
BEGIN
    IF v_t = '' THEN RETURN '{}'; END IF;

    v_out := ARRAY[ cifra_norm(regexp_replace(v_t, '[.,]', '', 'g')) ];

    IF v_t ~ '[.,]' THEN
        v_pre  := regexp_replace(v_t, '[.,][^.,]*$', '');   -- antes del último separador
        v_cola := regexp_replace(v_t, '^.*[.,]', '');       -- después del último separador
        v_out  := v_out || cifra_norm(
            regexp_replace(v_pre, '[.,]', '', 'g') || '.' || v_cola);
    END IF;

    RETURN ARRAY(SELECT DISTINCT x FROM unnest(v_out) AS x WHERE x <> '');
END;
$$;

CREATE OR REPLACE FUNCTION validar_cifras(p_texto text, p_hallazgos jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_permitidos text[];
    v_num        text;
    v_inventadas text[] := '{}';
BEGIN
    -- Los hallazgos son JSON: los números vienen con punto decimal y sin
    -- separador de miles, así que solo hay que normalizar los ceros de relleno.
    SELECT array_agg(DISTINCT cifra_norm(n)) INTO v_permitidos
    FROM (SELECT (regexp_matches(p_hallazgos::text, '\d+(?:\.\d+)?', 'g'))[1] AS n) s;

    FOR v_num IN
        SELECT m[1] FROM regexp_matches(coalesce(p_texto, ''), '\d[\d.,]*', 'g') AS m
    LOOP
        -- Los números de menos de 3 dígitos se ignoran: un "3 productos" o un
        -- "80 %" no son cifras copiadas de ningún lado.
        CONTINUE WHEN length(regexp_replace(v_num, '\D', '', 'g')) < 3;
        IF NOT (cifra_variantes(v_num) && v_permitidos) THEN
            v_inventadas := array_append(v_inventadas, v_num);
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'ok', cardinality(v_inventadas) = 0,
        'inventadas', to_jsonb(v_inventadas));
END;
$$;
