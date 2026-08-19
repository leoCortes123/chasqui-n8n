CREATE OR REPLACE FUNCTION public.ingesta_inferir_decimales(p_muestra jsonb, p_columnas jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
    v_vals   text[] := '{}';
    v_clave  text;
    v_col    text;
    v_fila   jsonb;
    v_txt    text;
BEGIN
    -- Solo los valores de las columnas numéricas: una descripción con comas
    -- no tiene por qué opinar sobre el separador decimal.
    FOREACH v_clave IN ARRAY ARRAY['cantidad','valor_unitario','valor_total','impuesto'] LOOP
        v_col := p_columnas ->> v_clave;
        CONTINUE WHEN v_col IS NULL;
        FOR v_fila IN SELECT * FROM jsonb_array_elements(coalesce(p_muestra,'[]'::jsonb)) LOOP
            v_txt := btrim(coalesce(v_fila ->> v_col, ''));
            IF v_txt <> '' THEN v_vals := v_vals || v_txt; END IF;
        END LOOP;
    END LOOP;

    -- 1.234,56 -> miles '.', decimal ','
    IF EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v ~ '^-?\d{1,3}(\.\d{3})+,\d+$') THEN
        RETURN jsonb_build_object('decimal', ',', 'miles', '.');
    END IF;
    -- 1,234.56 -> miles ',', decimal '.'
    IF EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v ~ '^-?\d{1,3}(,\d{3})+\.\d+$') THEN
        RETURN jsonb_build_object('decimal', '.', 'miles', ',');
    END IF;
    -- 1.234.567 sin decimales -> el punto es de miles
    IF EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v ~ '^-?\d{1,3}(\.\d{3})+$')
       AND NOT EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v ~ '^-?\d+\.\d{1,2}$') THEN
        RETURN jsonb_build_object('decimal', ',', 'miles', '.');
    END IF;
    -- 1234,56 sin separador de miles
    IF EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v ~ '^-?\d+,\d{1,2}$')
       AND NOT EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v ~ '^-?\d+\.\d+$') THEN
        RETURN jsonb_build_object('decimal', ',', 'miles', '');
    END IF;

    RETURN jsonb_build_object('decimal', '.', 'miles', '');
END;
$function$
