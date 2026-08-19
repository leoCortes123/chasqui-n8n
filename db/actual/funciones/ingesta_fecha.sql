CREATE OR REPLACE FUNCTION public.ingesta_fecha(p_valor jsonb, p_formato text DEFAULT NULL::text)
 RETURNS date
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
    v_txt text;
    v_n   numeric;
BEGIN
    IF p_valor IS NULL OR jsonb_typeof(p_valor) IN ('null','object','array') THEN
        RETURN NULL;
    END IF;

    -- Serial de Excel: los xlsx sin cellDates traen 46000 en vez de una fecha.
    -- La época de Excel es 1899-12-30 por su bug del año bisiesto de 1900.
    IF jsonb_typeof(p_valor) = 'number' THEN
        v_n := (p_valor #>> '{}')::numeric;
        IF v_n BETWEEN 20000 AND 80000 THEN
            RETURN date '1899-12-30' + (floor(v_n))::int;
        END IF;
        RETURN NULL;
    END IF;

    v_txt := btrim(p_valor #>> '{}');
    IF v_txt = '' THEN RETURN NULL; END IF;
    -- Recorta la parte de hora si viene (ISO o "12/03/2026 14:22").
    v_txt := split_part(split_part(v_txt, 'T', 1), ' ', 1);

    IF coalesce(p_formato, '') <> '' THEN
        RETURN to_date(v_txt, p_formato);
    END IF;

    -- Sin formato declarado solo se acepta ISO. dd/mm y mm/dd son
    -- indistinguibles y adivinar fue justo el bug de este archivo: mejor NULL
    -- y que la compuerta obligue a declarar formato_fecha en el mapeo.
    IF v_txt ~ '^\d{4}-\d{2}-\d{2}$' THEN
        RETURN v_txt::date;
    END IF;
    RETURN NULL;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$function$
