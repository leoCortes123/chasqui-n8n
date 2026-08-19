CREATE OR REPLACE FUNCTION public.periodo_resolver(p_texto text, p_defecto text, p_hasta date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_t     text := norm_texto(coalesce(p_texto, ''));
    v_mes   int;
    v_ano   int;
    v_desde date;
    v_fin   date;
    v_etq   text;
    v_meses text[] := ARRAY['enero','febrero','marzo','abril','mayo','junio',
                            'julio','agosto','septiembre','octubre','noviembre','diciembre'];
BEGIN
    -- ---- Un mes nombrado: "en marzo", "marzo del año pasado" ---------------
    -- Palabra COMPLETA (`\y`), no subcadena. Con LIKE '%mayo%', la pregunta
    -- "¿cuánto le compré a Mayorista Centro?" se respondía por el mes de mayo:
    -- el bot contestaba con seguridad una cifra que no era la que se le pidió,
    -- sin avisar de nada. Es la clase de error que hace que el dueño deje de
    -- creerle, y no lo atrapa ninguna prueba que no use nombres reales.
    SELECT i INTO v_mes FROM generate_subscripts(v_meses, 1) i
    WHERE v_t ~ ('\y' || v_meses[i] || '\y') LIMIT 1;

    IF v_mes IS NOT NULL THEN
        -- El año: el que se nombre, o el más reciente en que ese mes existe
        -- dentro de los datos. Preguntar por "marzo" en agosto es preguntar por
        -- el marzo de este año, no por el de hace tres.
        SELECT (regexp_matches(v_t, '\y(20\d{2})\y'))[1]::int INTO v_ano;
        IF v_ano IS NULL THEN
            v_ano := CASE WHEN v_mes <= extract(month FROM p_hasta)::int
                          THEN extract(year FROM p_hasta)::int
                          ELSE extract(year FROM p_hasta)::int - 1 END;
        END IF;
        IF v_t LIKE '%ano pasado%' OR v_t LIKE '%año pasado%' THEN
            v_ano := v_ano - 1;
        END IF;
        v_desde := make_date(v_ano, v_mes, 1);
        v_fin   := (v_desde + interval '1 month - 1 day')::date;
        RETURN jsonb_build_object('desde', v_desde, 'hasta', v_fin,
                                  'etiqueta', v_meses[v_mes] || ' de ' || v_ano,
                                  'origen', 'texto');
    END IF;

    -- ---- Expresiones relativas ---------------------------------------------
    v_etq := NULL;
    IF v_t LIKE '%este mes%' THEN
        v_desde := date_trunc('month', p_hasta)::date;
        v_fin   := p_hasta; v_etq := 'este mes';
    ELSIF v_t LIKE '%mes pasado%' OR v_t LIKE '%mes anterior%' THEN
        v_desde := (date_trunc('month', p_hasta) - interval '1 month')::date;
        v_fin   := (date_trunc('month', p_hasta) - interval '1 day')::date;
        v_etq   := 'el mes pasado';
    ELSIF v_t LIKE '%ano pasado%' THEN
        v_desde := make_date(extract(year FROM p_hasta)::int - 1, 1, 1);
        v_fin   := make_date(extract(year FROM p_hasta)::int - 1, 12, 31);
        v_etq   := 'el año pasado';
    ELSIF v_t LIKE '%este ano%' THEN
        v_desde := date_trunc('year', p_hasta)::date;
        v_fin   := p_hasta; v_etq := 'este año';
    ELSIF v_t ~ 'ultim[oa]s? +\d+ +dias' THEN
        v_desde := p_hasta - ((regexp_matches(v_t, 'ultim[oa]s? +(\d+) +dias'))[1]::int);
        v_fin   := p_hasta;
        v_etq   := 'los últimos ' || (p_hasta - v_desde) || ' días';
    END IF;

    IF v_etq IS NOT NULL THEN
        RETURN jsonb_build_object('desde', v_desde, 'hasta', v_fin,
                                  'etiqueta', v_etq, 'origen', 'texto');
    END IF;

    -- ---- El defecto de la intención ----------------------------------------
    RETURN CASE p_defecto
      WHEN 'mes_actual' THEN jsonb_build_object(
        'desde', date_trunc('month', p_hasta)::date, 'hasta', p_hasta,
        'etiqueta', 'este mes', 'origen', 'defecto')
      WHEN 'mes_anterior' THEN jsonb_build_object(
        'desde', (date_trunc('month', p_hasta) - interval '1 month')::date,
        'hasta', (date_trunc('month', p_hasta) - interval '1 day')::date,
        'etiqueta', 'el mes pasado', 'origen', 'defecto')
      WHEN 'ano_actual' THEN jsonb_build_object(
        'desde', date_trunc('year', p_hasta)::date, 'hasta', p_hasta,
        'etiqueta', 'este año', 'origen', 'defecto')
      WHEN 'ultimos_30' THEN jsonb_build_object(
        'desde', p_hasta - 30, 'hasta', p_hasta,
        'etiqueta', 'los últimos 30 días', 'origen', 'defecto')
      ELSE jsonb_build_object(
        'desde', NULL, 'hasta', NULL,
        'etiqueta', 'toda tu historia cargada', 'origen', 'defecto')
    END;
END;
$function$
