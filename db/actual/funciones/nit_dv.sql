CREATE OR REPLACE FUNCTION public.nit_dv(p_nit text)
 RETURNS integer
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
    v_pesos int[] := ARRAY[3,7,13,17,19,23,29,37,41,43,47,53,59,67,71];
    v_suma  int := 0;
    v_res   int;
    i       int;
BEGIN
    IF p_nit !~ '^\d{1,15}$' THEN
        RETURN NULL;
    END IF;
    FOR i IN 1..length(p_nit) LOOP
        -- dígito i-ésimo desde la derecha por el peso i-ésimo
        v_suma := v_suma + substr(p_nit, length(p_nit) - i + 1, 1)::int * v_pesos[i];
    END LOOP;
    v_res := v_suma % 11;
    RETURN CASE WHEN v_res IN (0, 1) THEN v_res ELSE 11 - v_res END;
END;
$function$
