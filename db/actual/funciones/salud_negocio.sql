CREATE OR REPLACE FUNCTION public.salud_negocio(p_negocio_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_margen_min numeric := coalesce((parametro(p_negocio_id,'margen_minimo_pct'))::text::numeric, 20);
    v_dias_cob   numeric := coalesce((parametro(p_negocio_id,'dias_cobertura_min'))::text::numeric, 7);
    v_lenta      numeric := coalesce((parametro(p_negocio_id,'rotacion_lenta_dias'))::text::numeric, 60);
    v_deriva_ali numeric := coalesce((parametro(p_negocio_id,'deriva_costo_alerta_pct'))::text::numeric, 8);
    v_ventas     numeric;
    v_margenes   numeric;
    v_inventario numeric;
    v_compras    numeric;
    v_riesgos    numeric;
    v_liquidez   numeric;
    v_indice     numeric;
    v_mitad      date;
    v_desde      date;
    v_hasta      date;
    v_inv_est    boolean;
BEGIN
    SELECT min(fecha), max(fecha) INTO v_desde, v_hasta
    FROM mov_visibles WHERE negocio_id = p_negocio_id AND fecha IS NOT NULL;

    -- --- Ventas: ¿la segunda mitad del periodo vendió más que la primera? ----
    IF v_desde IS NOT NULL AND v_hasta - v_desde >= 14 THEN
        v_mitad := v_desde + ((v_hasta - v_desde) / 2);
        SELECT CASE WHEN coalesce(sum(valor_total) FILTER (WHERE fecha <= v_mitad), 0) > 0
                    THEN least(100, greatest(0, round(50 +
                          (coalesce(sum(valor_total) FILTER (WHERE fecha > v_mitad), 0)
                           - sum(valor_total) FILTER (WHERE fecha <= v_mitad))
                          * 100.0 / sum(valor_total) FILTER (WHERE fecha <= v_mitad))))
               END
          INTO v_ventas
        FROM mov_visibles
        WHERE negocio_id = p_negocio_id AND tipo = 'venta' AND fecha IS NOT NULL;
    END IF;

    -- --- Márgenes: qué porcentaje de los productos con precio llega al mínimo -
    SELECT CASE WHEN count(*) > 0
                THEN round(count(*) FILTER (WHERE margen_pct >= v_margen_min) * 100.0 / count(*))
           END
      INTO v_margenes
    FROM v_margen_producto
    WHERE negocio_id = p_negocio_id AND precio_actual IS NOT NULL AND margen_pct IS NOT NULL;

    -- --- Inventario: qué porcentaje está en cobertura sana -------------------
    SELECT CASE WHEN count(*) > 0
                THEN round(count(*) FILTER (WHERE dias_cobertura BETWEEN v_dias_cob AND v_lenta)
                           * 100.0 / count(*))
           END
      INTO v_inventario
    FROM v_rotacion_producto
    WHERE negocio_id = p_negocio_id AND dias_cobertura IS NOT NULL;

    -- --- Compras: cuántos productos NO tienen el costo disparado ------------
    SELECT CASE WHEN count(*) > 0
                THEN round(count(*) FILTER (WHERE deriva_pct < v_deriva_ali) * 100.0 / count(*))
           END
      INTO v_compras
    FROM v_deriva_costo WHERE negocio_id = p_negocio_id;

    -- --- Riesgos: concentración de compras en un solo proveedor -------------
    SELECT CASE WHEN sum(gasto) > 0
                THEN least(100, greatest(0,
                       round(100 - (max(gasto) * 100.0 / sum(gasto))
                                 + 20)))   -- un 40% de concentración ya es sano
           END
      INTO v_riesgos
    FROM (SELECT nullif(btrim(coalesce(raw ->> 'proveedor','')),'') AS prov,
                 sum(valor_total) AS gasto
          FROM mov_visibles
          WHERE negocio_id = p_negocio_id AND tipo = 'compra'
            AND nullif(btrim(coalesce(raw ->> 'proveedor','')),'') IS NOT NULL
          GROUP BY 1) t;

    -- --- >>> 069. Liquidez: qué parte de lo que te deben está al día --------
    -- NULL si el negocio no tiene una sola factura a crédito, igual que las
    -- otras cinco. Un negocio que vende todo de contado no tiene por qué ver
    -- bajar su índice por una nota que no le aplica.
    SELECT CASE WHEN sum(saldo) > 0
                THEN round(100 - (coalesce(sum(saldo) FILTER (
                       WHERE vencimiento IS NOT NULL AND vencimiento < current_date), 0)
                     * 100.0 / sum(saldo)))
           END
      INTO v_liquidez
    FROM facturas
    WHERE negocio_id = p_negocio_id AND tipo = 'venta' AND saldo > 0;

    -- >>> 054: ¿la nota de inventario se calculó sobre stock estimado?
    SELECT bool_or(origen_stock = 'estimado') INTO v_inv_est
    FROM v_rotacion_producto
    WHERE negocio_id = p_negocio_id AND dias_cobertura IS NOT NULL;

    SELECT round(avg(n)) INTO v_indice
    FROM unnest(ARRAY[v_ventas, v_margenes, v_inventario, v_compras,
                      v_riesgos, v_liquidez]) AS n
    WHERE n IS NOT NULL;

    IF v_indice IS NULL THEN
        RETURN NULL;   -- sin datos suficientes, no se dibuja el semáforo
    END IF;

    RETURN jsonb_strip_nulls(jsonb_build_object(
        'ventas', v_ventas, 'margenes', v_margenes, 'inventario', v_inventario,
        'compras', v_compras, 'riesgos', v_riesgos, 'liquidez', v_liquidez,
        'indice', v_indice,
        'inventario_estimado', CASE WHEN v_inventario IS NULL THEN NULL
                                    ELSE coalesce(v_inv_est, false) END));
END;
$function$
