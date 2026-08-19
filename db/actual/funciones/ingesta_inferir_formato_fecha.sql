CREATE OR REPLACE FUNCTION public.ingesta_inferir_formato_fecha(p_muestra jsonb, p_columna text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
    v_vals text[] := '{}';
    v_fila jsonb;
    v_txt  text;
    v_sep  text;
    v_a    int;
    v_b    int;
BEGIN
    IF p_columna IS NULL THEN RETURN NULL; END IF;

    FOR v_fila IN SELECT * FROM jsonb_array_elements(coalesce(p_muestra,'[]'::jsonb)) LOOP
        v_txt := btrim(coalesce(v_fila ->> p_columna, ''));
        -- Se recorta la hora igual que ingesta_fecha, para comparar lo mismo.
        v_txt := split_part(split_part(v_txt, 'T', 1), ' ', 1);
        IF v_txt <> '' THEN v_vals := v_vals || v_txt; END IF;
    END LOOP;

    IF cardinality(v_vals) = 0 THEN RETURN NULL; END IF;

    -- ISO: sin ambigüedad posible.
    IF NOT EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v !~ '^\d{4}-\d{2}-\d{2}$') THEN
        RETURN 'YYYY-MM-DD';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v !~ '^\d{4}/\d{2}/\d{2}$') THEN
        RETURN 'YYYY/MM/DD';
    END IF;

    -- dd?s?mm?s?yyyy: hay que decidir cuál de los dos primeros es el día.
    IF NOT EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v !~ '^\d{1,2}[/-]\d{1,2}[/-]\d{4}$') THEN
        v_sep := CASE WHEN v_vals[1] ~ '-' THEN '-' ELSE '/' END;
        SELECT max(split_part(v, v_sep, 1)::int), max(split_part(v, v_sep, 2)::int)
          INTO v_a, v_b FROM unnest(v_vals) v;
        -- Un primer componente > 12 solo puede ser un día.
        IF v_a > 12 THEN RETURN 'DD' || v_sep || 'MM' || v_sep || 'YYYY'; END IF;
        -- Un segundo componente > 12 solo puede ser un día.
        IF v_b > 12 THEN RETURN 'MM' || v_sep || 'DD' || v_sep || 'YYYY'; END IF;
        -- Ambiguo de verdad: comercio latinoamericano, DD/MM. Es la misma
        -- convención que ya declara el prompt del modelo.
        RETURN 'DD' || v_sep || 'MM' || v_sep || 'YYYY';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v !~ '^\d{1,2}[/-]\d{1,2}[/-]\d{2}$') THEN
        v_sep := CASE WHEN v_vals[1] ~ '-' THEN '-' ELSE '/' END;
        SELECT max(split_part(v, v_sep, 1)::int) INTO v_a FROM unnest(v_vals) v;
        IF v_a > 12 THEN RETURN 'DD' || v_sep || 'MM' || v_sep || 'YY'; END IF;
        RETURN 'DD' || v_sep || 'MM' || v_sep || 'YY';
    END IF;

    -- Serial de Excel u otra cosa: NULL y que decida ingesta_fecha, que ya sabe
    -- convertir el serial y devolver NULL en vez de un dato equivocado.
    RETURN NULL;
END;
$function$
