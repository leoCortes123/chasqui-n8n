CREATE OR REPLACE FUNCTION public.cifra_variantes(p_num text)
 RETURNS text[]
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
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
$function$
