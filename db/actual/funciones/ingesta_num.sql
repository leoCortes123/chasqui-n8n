CREATE OR REPLACE FUNCTION public.ingesta_num(p_valor jsonb, p_decimal text DEFAULT '.'::text, p_miles text DEFAULT ','::text)
 RETURNS numeric
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
    v_txt text;
    v_neg boolean := false;
BEGIN
    IF p_valor IS NULL OR jsonb_typeof(p_valor) IN ('null','object','array') THEN
        RETURN NULL;
    END IF;

    -- Ya es número: no tocarlo.
    IF jsonb_typeof(p_valor) = 'number' THEN
        RETURN (p_valor #>> '{}')::numeric;
    END IF;

    v_txt := btrim(p_valor #>> '{}');
    IF v_txt = '' THEN RETURN NULL; END IF;

    -- Negativo contable: (1.234,50)
    IF v_txt ~ '^\(.*\)$' THEN
        v_neg := true;
        v_txt := btrim(v_txt, '()');
    END IF;
    IF v_txt ~ '^-' THEN v_neg := true; END IF;

    -- Primero los miles (se van), después la coma decimal pasa a punto.
    IF coalesce(p_miles, '') <> '' THEN
        v_txt := replace(v_txt, p_miles, '');
    END IF;
    IF coalesce(p_decimal, '.') <> '.' THEN
        v_txt := replace(v_txt, p_decimal, '.');
    END IF;

    -- Fuera símbolo de moneda, espacios (incluido el no-separable), letras.
    v_txt := regexp_replace(v_txt, '[^0-9.]', '', 'g');
    IF v_txt = '' OR v_txt = '.' THEN RETURN NULL; END IF;

    -- Un archivo mal declarado puede dejar varios puntos: no adivinar.
    IF length(v_txt) - length(replace(v_txt, '.', '')) > 1 THEN
        RETURN NULL;
    END IF;

    RETURN CASE WHEN v_neg THEN -v_txt::numeric ELSE v_txt::numeric END;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;   -- un valor ilegible es NULL, y la compuerta lo cuenta
END;
$function$
