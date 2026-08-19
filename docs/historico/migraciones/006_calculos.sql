-- 006_calculos.sql — la aritmética vive en vistas, no en plpgsql.
-- Depurar márgenes desde un SELECT es trivial; desde una función, miserable.
-- hallazgos_generar solo LEE de estas vistas, aplica umbrales y arma el JSON.

-- Costo actual = valor unitario de la compra más reciente por producto.
CREATE VIEW v_costo_actual_producto AS
SELECT DISTINCT ON (m.negocio_id, m.producto_id)
       m.negocio_id, m.producto_id,
       m.valor_unitario AS costo_actual,
       m.fecha          AS fecha_costo
FROM movimientos m
WHERE m.tipo = 'compra' AND m.producto_id IS NOT NULL AND m.valor_unitario IS NOT NULL
ORDER BY m.negocio_id, m.producto_id, m.fecha DESC NULLS LAST, m.id DESC;

-- Precio actual = valor unitario de la venta más reciente por producto.
CREATE VIEW v_precio_actual_producto AS
SELECT DISTINCT ON (m.negocio_id, m.producto_id)
       m.negocio_id, m.producto_id,
       m.valor_unitario AS precio_actual,
       m.fecha          AS fecha_precio
FROM movimientos m
WHERE m.tipo = 'venta' AND m.producto_id IS NOT NULL AND m.valor_unitario IS NOT NULL
ORDER BY m.negocio_id, m.producto_id, m.fecha DESC NULLS LAST, m.id DESC;

-- Margen = precio de venta contra costo de reposición.
CREATE VIEW v_margen_producto AS
SELECT p.negocio_id, p.id AS producto_id, p.nombre_canonico,
       c.costo_actual, pr.precio_actual,
       (pr.precio_actual - c.costo_actual)                          AS margen_abs,
       round(((pr.precio_actual - c.costo_actual)
              / nullif(pr.precio_actual, 0) * 100)::numeric, 2)     AS margen_pct
FROM productos p
LEFT JOIN v_costo_actual_producto  c  ON c.negocio_id  = p.negocio_id AND c.producto_id  = p.id
LEFT JOIN v_precio_actual_producto pr ON pr.negocio_id = p.negocio_id AND pr.producto_id = p.id;

-- Deriva de costo = cuánto se movió el costo entre la primera y la última compra.
CREATE VIEW v_deriva_costo AS
WITH compras AS (
    SELECT negocio_id, producto_id, valor_unitario, fecha, id,
           first_value(valor_unitario) OVER w AS costo_ini,
           last_value(valor_unitario)  OVER w AS costo_fin
    FROM movimientos
    WHERE tipo = 'compra' AND producto_id IS NOT NULL AND valor_unitario IS NOT NULL
    WINDOW w AS (PARTITION BY negocio_id, producto_id
                 ORDER BY fecha NULLS FIRST, id
                 ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
)
SELECT DISTINCT negocio_id, producto_id, costo_ini, costo_fin,
       (costo_fin - costo_ini)                                   AS deriva_abs,
       round(((costo_fin - costo_ini)
              / nullif(costo_ini, 0) * 100)::numeric, 2)         AS deriva_pct
FROM compras;

-- Balance de unidades = compradas menos vendidas (inventario implícito).
CREATE VIEW v_balance_unidades AS
SELECT p.negocio_id, p.id AS producto_id,
       coalesce(sum(m.cantidad) FILTER (WHERE m.tipo = 'compra'), 0) AS compradas,
       coalesce(sum(m.cantidad) FILTER (WHERE m.tipo = 'venta'), 0)  AS vendidas,
       coalesce(sum(m.cantidad) FILTER (WHERE m.tipo = 'compra'), 0)
         - coalesce(sum(m.cantidad) FILTER (WHERE m.tipo = 'venta'), 0) AS balance
FROM productos p
LEFT JOIN movimientos m ON m.producto_id = p.id
GROUP BY p.negocio_id, p.id;

-- Rotación = unidades vendidas por día sobre la ventana observada, y días de
-- cobertura = cuánto dura el balance actual a ese ritmo.
CREATE VIEW v_rotacion_producto AS
WITH ventas AS (
    SELECT negocio_id, producto_id,
           sum(cantidad)                                   AS unidades,
           greatest(max(fecha) - min(fecha), 1)            AS dias_ventana
    FROM movimientos
    WHERE tipo = 'venta' AND producto_id IS NOT NULL
    GROUP BY negocio_id, producto_id
)
SELECT v.negocio_id, v.producto_id,
       v.unidades, v.dias_ventana,
       round((v.unidades::numeric / v.dias_ventana), 3)    AS unidades_por_dia,
       CASE WHEN v.unidades > 0
            THEN round(b.balance / (v.unidades::numeric / v.dias_ventana), 1)
       END                                                 AS dias_cobertura
FROM ventas v
LEFT JOIN v_balance_unidades b
       ON b.negocio_id = v.negocio_id AND b.producto_id = v.producto_id;

-- Pareto de utilidad = qué productos concentran la ganancia.
CREATE VIEW v_pareto_utilidad AS
WITH util AS (
    SELECT m.negocio_id, m.producto_id,
           sum((m.valor_unitario - c.costo_actual) * m.cantidad) AS utilidad
    FROM movimientos m
    JOIN v_costo_actual_producto c
      ON c.negocio_id = m.negocio_id AND c.producto_id = m.producto_id
    WHERE m.tipo = 'venta' AND m.producto_id IS NOT NULL
    GROUP BY m.negocio_id, m.producto_id
),
ranked AS (
    SELECT negocio_id, producto_id, utilidad,
           sum(utilidad) OVER (PARTITION BY negocio_id)                  AS utilidad_total,
           sum(utilidad) OVER (PARTITION BY negocio_id
                               ORDER BY utilidad DESC
                               ROWS UNBOUNDED PRECEDING)                 AS utilidad_acum
    FROM util
)
SELECT negocio_id, producto_id, utilidad,
       round((utilidad     / nullif(utilidad_total, 0) * 100)::numeric, 2) AS pct_utilidad,
       round((utilidad_acum / nullif(utilidad_total, 0) * 100)::numeric, 2) AS pct_acumulado
FROM ranked
ORDER BY negocio_id, utilidad DESC;

-- === hallazgos_generar =====================================================
-- Lee las vistas, aplica los umbrales de parametros y arma el JSON que verá
-- el LLM. Nada de aritmética suelta: solo lectura, comparación y ensamblaje.
CREATE FUNCTION hallazgos_generar(p_negocio_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_margen_min  numeric := (parametro(p_negocio_id, 'margen_minimo_pct'))::text::numeric;
    v_deriva_ali  numeric := (parametro(p_negocio_id, 'deriva_costo_alerta_pct'))::text::numeric;
    v_dias_cob    numeric := (parametro(p_negocio_id, 'dias_cobertura_min'))::text::numeric;
    v_out jsonb;
BEGIN
    SELECT jsonb_build_object(
      'negocio_id', p_negocio_id,
      'generado_en', now(),
      'umbrales', jsonb_build_object('margen_minimo_pct', v_margen_min,
                                     'deriva_costo_alerta_pct', v_deriva_ali,
                                     'dias_cobertura_min', v_dias_cob),

      'resumen', (SELECT jsonb_build_object(
                    'productos', count(*),
                    'con_precio', count(*) FILTER (WHERE precio_actual IS NOT NULL),
                    'margen_promedio_pct', round(avg(margen_pct), 2))
                  FROM v_margen_producto WHERE negocio_id = p_negocio_id),

      'margen_bajo', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'producto', nombre_canonico, 'costo', costo_actual,
                        'precio', precio_actual, 'margen_pct', margen_pct)
                        ORDER BY margen_pct), '[]')
                      FROM v_margen_producto
                      WHERE negocio_id = p_negocio_id
                        AND precio_actual IS NOT NULL
                        AND margen_pct < v_margen_min),

      'deriva_costo', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'producto_id', d.producto_id, 'producto', p.nombre_canonico,
                        'costo_ini', d.costo_ini, 'costo_fin', d.costo_fin,
                        'deriva_pct', d.deriva_pct) ORDER BY abs(d.deriva_pct) DESC), '[]')
                      FROM v_deriva_costo d JOIN productos p ON p.id = d.producto_id
                      WHERE d.negocio_id = p_negocio_id
                        AND abs(d.deriva_pct) >= v_deriva_ali),

      'baja_cobertura', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'producto_id', r.producto_id, 'producto', p.nombre_canonico,
                        'dias_cobertura', r.dias_cobertura,
                        'unidades_por_dia', r.unidades_por_dia) ORDER BY r.dias_cobertura), '[]')
                      FROM v_rotacion_producto r JOIN productos p ON p.id = r.producto_id
                      WHERE r.negocio_id = p_negocio_id
                        AND r.dias_cobertura IS NOT NULL
                        AND r.dias_cobertura < v_dias_cob),

      'pareto', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'producto', p.nombre_canonico, 'utilidad', pa.utilidad,
                        'pct_utilidad', pa.pct_utilidad, 'pct_acumulado', pa.pct_acumulado)
                        ORDER BY pa.utilidad DESC), '[]')
                      FROM v_pareto_utilidad pa JOIN productos p ON p.id = pa.producto_id
                      WHERE pa.negocio_id = p_negocio_id AND pa.pct_acumulado <= 80)
    ) INTO v_out;

    RETURN v_out;
END;
$$;
