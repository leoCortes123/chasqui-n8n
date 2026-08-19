CREATE OR REPLACE FUNCTION public.intencion_resolver(p_negocio_id bigint, p_texto text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_cod    text := intencion_detectar(p_texto);
    v_i      record;
    v_hasta  date;
    v_per    jsonb;
    v_prod   bigint;
    v_prodn  text;
    v_prov   text;
    v_comp   jsonb;
    v_d      date;
    v_h      date;
BEGIN
    IF v_cod IS NULL THEN RETURN NULL; END IF;

    SELECT * INTO v_i FROM intenciones WHERE codigo = v_cod;

    SELECT max(fecha) INTO v_hasta
    FROM mov_visibles WHERE negocio_id = p_negocio_id AND fecha IS NOT NULL;
    IF v_hasta IS NULL THEN RETURN NULL; END IF;   -- sin datos no hay agregado

    v_per := periodo_resolver(p_texto, v_i.periodo, v_hasta);
    v_d := nullif(v_per ->> 'desde', '')::date;
    v_h := nullif(v_per ->> 'hasta', '')::date;

    -- ---- Filtros: solo los que la intención declara aceptar -----------------
    -- El nombre del producto se busca por parecido, con el mismo trigram del
    -- matching (005). Un umbral alto a propósito: preferimos no filtrar a
    -- filtrar por el producto equivocado y dar una cifra que no es.
    IF 'producto' = ANY (v_i.filtros) THEN
        -- `word_similarity` y no `similarity`: la pregunta es larga y el
        -- nombre del producto es corto, así que comparar las dos cadenas
        -- enteras castiga al producto por el largo de la pregunta. Con
        -- "¿cuánto stock me queda de yogurt?", similarity da 0,167 —por debajo
        -- de cualquier umbral razonable— y word_similarity da 0,412.
        SELECT id, nombre_canonico INTO v_prod, v_prodn
        FROM productos
        WHERE negocio_id = p_negocio_id
          AND word_similarity(norm_texto(nombre_canonico), norm_texto(p_texto)) > 0.35
        ORDER BY word_similarity(norm_texto(nombre_canonico), norm_texto(p_texto)) DESC
        LIMIT 1;
    END IF;

    IF 'proveedor' = ANY (v_i.filtros) THEN
        SELECT prov INTO v_prov FROM (
            SELECT DISTINCT nullif(btrim(coalesce(raw ->> 'proveedor','')),'') AS prov
            FROM mov_visibles WHERE negocio_id = p_negocio_id AND tipo = 'compra') s
        WHERE prov IS NOT NULL
          AND word_similarity(norm_texto(prov), norm_texto(p_texto)) > 0.35
        ORDER BY word_similarity(norm_texto(prov), norm_texto(p_texto)) DESC
        LIMIT 1;
    END IF;

    -- ---- Comparativo --------------------------------------------------------
    IF v_i.comparativo IS NOT NULL AND v_d IS NOT NULL THEN
        IF v_i.comparativo = 'mismo_mes_ano_pasado' THEN
            v_comp := jsonb_build_object(
              'contra', 'el mismo periodo del año pasado',
              'desde', (v_d - interval '1 year')::date,
              'hasta', (v_h - interval '1 year')::date,
              'agregados', intencion_agregados(p_negocio_id, v_i.metrica,
                             (v_d - interval '1 year')::date,
                             (v_h - interval '1 year')::date, v_prod, v_prov));
        ELSE
            v_comp := jsonb_build_object(
              'contra', 'el periodo anterior',
              'desde', (v_d - (v_h - v_d) - 1)::date, 'hasta', (v_d - 1)::date,
              'agregados', intencion_agregados(p_negocio_id, v_i.metrica,
                             (v_d - (v_h - v_d) - 1)::date, (v_d - 1)::date,
                             v_prod, v_prov));
        END IF;

        -- "No tengo datos de entonces" no es "vendiste $0". Sin esta distinción
        -- el modelo contesta "el año pasado fue $0", que es falso y además
        -- suena a que el negocio se hundió. Si no hay un solo movimiento en la
        -- ventana de comparación, se dice eso y no una cifra.
        IF coalesce((v_comp #>> '{agregados,movimientos}')::int, 0) = 0 THEN
            v_comp := jsonb_build_object(
              'contra', v_comp ->> 'contra',
              'desde', v_comp -> 'desde', 'hasta', v_comp -> 'hasta',
              'sin_datos', true,
              'nota', 'No hay datos cargados de ese periodo, así que no se puede comparar.');
        END IF;
    END IF;

    RETURN jsonb_strip_nulls(jsonb_build_object(
      'intencion', v_i.codigo,
      'nombre', v_i.nombre,
      'metrica', v_i.metrica,
      'periodo', v_per,
      'filtros', jsonb_strip_nulls(jsonb_build_object(
                   'producto', v_prodn, 'proveedor', v_prov)),
      'agregados', intencion_agregados(p_negocio_id, v_i.metrica, v_d, v_h,
                                       v_prod, v_prov),
      'comparativo', v_comp));
END;
$function$
