CREATE OR REPLACE FUNCTION public.recomendaciones_medir(p_negocio_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    r        record;
    v_ahora  numeric;
    v_antes  numeric;
    v_delta  numeric;
    v_res    text;
    v_n      jsonb := jsonb_build_object('positivo', 0, 'neutro', 0,
                                         'negativo', 0, 'sin_datos', 0);
BEGIN
    FOR r IN
        SELECT re.*, m.metrica, m.direccion, m.umbral_pct
        FROM recomendaciones re
        JOIN metricas_resultado m ON m.regla = re.regla
        WHERE re.negocio_id = p_negocio_id
          AND re.estado NOT IN ('nueva','vigente')
          AND re.resultado IS NULL
          AND re.cerrada_en IS NOT NULL
          AND re.datos ? 'valor_al_cerrar'
    LOOP
        -- ¿Llegaron datos después del cierre? Se mira `creado_en` y NO `fecha`:
        -- un archivo con ventas fechadas la semana que viene ya estaba cargado
        -- cuando se cerró la recomendación, así que no dice nada sobre si la
        -- acción sirvió. Lo que importa es que haya entrado información nueva,
        -- no que haya filas con fecha posterior.
        IF NOT EXISTS (SELECT 1 FROM mov_visibles
                        WHERE negocio_id = p_negocio_id
                          AND creado_en > r.cerrada_en) THEN
            v_n := jsonb_set(v_n, '{sin_datos}',
                     to_jsonb((v_n ->> 'sin_datos')::int + 1));
            CONTINUE;
        END IF;

        v_antes := nullif(r.datos ->> 'valor_al_cerrar', '')::numeric;
        v_ahora := recomendacion_metrica_valor(p_negocio_id, r.clave_objeto,
                                               r.metrica, r.cerrada_en::date);

        IF v_ahora IS NULL OR v_antes IS NULL THEN
            v_n := jsonb_set(v_n, '{sin_datos}',
                     to_jsonb((v_n ->> 'sin_datos')::int + 1));
            CONTINUE;
        END IF;

        -- Cambio relativo. Con un valor de partida en cero —el caso de las
        -- magnitudes de flujo— cualquier movimiento es 100%: es lo correcto,
        -- porque ahí la pregunta es "¿pasó algo?" y no "¿cuánto cambió?".
        v_delta := CASE WHEN coalesce(v_antes, 0) = 0
                        THEN CASE WHEN v_ahora = 0 THEN 0 ELSE 100 END
                        ELSE (v_ahora - v_antes) * 100.0 / abs(v_antes) END;

        v_res := CASE
          WHEN abs(v_delta) < r.umbral_pct THEN 'neutro'
          WHEN (r.direccion = 'sube_mejor' AND v_delta > 0)
            OR (r.direccion = 'baja_mejor' AND v_delta < 0) THEN 'positivo'
          ELSE 'negativo' END;

        UPDATE recomendaciones
           SET resultado = v_res,
               datos = coalesce(datos, '{}'::jsonb) || jsonb_build_object(
                         'valor_al_medir', round(v_ahora, 4),
                         'cambio_pct', round(v_delta, 1),
                         'medido_en', current_date)
         WHERE id = r.id;

        v_n := jsonb_set(v_n, ARRAY[v_res], to_jsonb((v_n ->> v_res)::int + 1));
    END LOOP;

    RETURN v_n;
END;
$function$
