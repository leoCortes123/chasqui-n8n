-- 053_historia_completa.sql — el plan limita lo que se LEE, nunca lo que se
-- guarda.
--
-- La 051 puso el límite del plan gratuito en un trigger BEFORE INSERT sobre
-- `movimientos` que devuelve NULL: lo que caía fuera de la ventana de 3 meses
-- simplemente no se guardaba. El razonamiento era bueno —una sola regla, en un
-- solo lugar, cubriendo todos los caminos de ingesta presentes y futuros— pero
-- el lugar era el equivocado, y tiene tres consecuencias que no se ven hasta
-- que es tarde:
--
--   1. Un negocio que pasa a plan pago NO recupera nada. La historia que mandó
--      mientras era free no existe: hay que pedirle que vuelva a subir doce
--      meses de archivos, justo en el momento en que acaba de pagar.
--   2. Ningún comparativo interanual es posible, ni ahora ni nunca, porque el
--      dato contra el que se compararía se descartó en el momento de cargarlo.
--   3. El daño es irreversible y silencioso: no hay papelera, no hay aviso al
--      operador, y el usuario solo ve un contador al pie de un mensaje.
--
-- Chasqui se define como el sistema que conoce el negocio. Un sistema que borra
-- la historia de sus clientes por su plan de precios no puede serlo. La regla
-- pasa a ser: **el plan limita lectura y capacidad, jamás almacenamiento**.
--
-- POR QUÉ ESTA MIGRACIÓN TOCA TANTAS COSAS A LA VEZ
--
-- Porque hoy el filtro es de escritura, y por eso NINGÚN lector tiene filtro:
-- las siete vistas de la 006, las funciones de análisis de la 047 y la 043
-- leen `movimientos` sin condición de fecha. Cambiar solo el trigger dejaría
-- el plan gratuito sin efecto alguno —todos los negocios free pasarían a
-- analizar historia ilimitada— y nadie se enteraría. El filtro se mueve de
-- escritura a lectura de una sola vez, o el sistema queda incoherente.
--
-- CÓMO
--
-- Una vista, `mov_visibles`, es la fuente de lectura de todo lo que analiza.
-- `movimientos` sigue siendo la tabla, y sigue siendo lo que ve todo lo que
-- ESCRIBE o CORRIGE: el matching resuelve productos sobre lo almacenado, la
-- cartera re-factura sobre lo almacenado, y el resumen de un archivo cuenta lo
-- que ese archivo trajo. Si el filtro se aplicara también ahí, confirmar un
-- alias dejaría de arreglar los movimientos viejos y `cartera_refacturar`
-- saltaría facturas en silencio: el mismo tipo de bug que esta migración viene
-- a cerrar.
--
-- Reparto explícito:
--
--   LEEN `mov_visibles` (análisis, y por lo tanto sujeto al plan):
--     v_costo_actual_producto, v_precio_actual_producto, v_margen_producto,
--     v_deriva_costo, v_balance_unidades, v_rotacion_producto,
--     v_pareto_utilidad, hallazgos_generar, recomendaciones_negocio,
--     salud_negocio, hallazgos_compras.
--
--   SIGUEN LEYENDO `movimientos` (escritura, corrección y contabilidad de lo
--   cargado, que no debe depender del plan):
--     match_resolver_documento, match_confirmar_alias, cartera_facturar_dian,
--     ingesta_resumen_documento, ingesta_resumen_sesion, y las RPC del portal
--     —el portal muestra lo que el usuario cargó, que es precisamente el
--     argumento para que suba de plan—.
--
-- Las funciones de análisis se reproducen íntegras porque en SQL no hay parche
-- parcial: lo único que cambia en cada una es el nombre de la relación en el
-- FROM. La sustitución se hizo de forma mecánica sobre el texto de la 047 y la
-- 043 para no arrastrar cambios de contrabando.

-- =============================================================================
-- 1. El trigger deja de descartar
-- =============================================================================
-- Mismo trigger, misma cuenta de filas fuera de ventana —el aviso al usuario
-- sigue siendo útil—, pero la fila SE GUARDA. `filas_fuera_de_plan` pasa de
-- "cuántas tiré" a "cuántas quedaron esperando a que subas de plan", y por eso
-- caduca sola: la ventana se corre cada mes calendario. Es un dato del momento
-- de la carga, no un estado permanente, y así se usa.
CREATE OR REPLACE FUNCTION movimientos_limite_plan() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_desde date;
BEGIN
    IF NEW.fecha IS NULL THEN RETURN NEW; END IF;

    v_desde := plan_desde(NEW.negocio_id);
    IF v_desde IS NULL OR NEW.fecha >= v_desde THEN RETURN NEW; END IF;

    IF NEW.documento_id IS NOT NULL THEN
        UPDATE documentos SET filas_fuera_de_plan = filas_fuera_de_plan + 1
        WHERE id = NEW.documento_id;
    END IF;
    RETURN NEW;   -- fuera de la ventana de LECTURA, pero se guarda igual
END;
$$;

-- =============================================================================
-- 2. mov_visibles: la fuente de lectura del análisis
-- =============================================================================
-- `plan_desde` devuelve NULL para todo plan que no sea free (= sin límite), y
-- para free el primer día del mes calendario que abre la ventana. Las filas sin
-- fecha nunca se ocultan: no se pueden ubicar en el tiempo, ya las mide la
-- compuerta de calidad de la 017, y esconderlas sería perder el aviso.
--
-- El filtro llama a `plan_desde` por fila. En la práctica toda consulta de
-- análisis lleva `negocio_id = <constante>`, así que el planner evalúa la
-- función una sola vez; y el volumen de una pyme no justifica materializar
-- nada. Si algún día lo justifica, el cambio queda contenido en esta vista.
CREATE OR REPLACE VIEW mov_visibles AS
SELECT m.*
FROM movimientos m
WHERE m.fecha IS NULL
   OR plan_desde(m.negocio_id) IS NULL
   OR m.fecha >= plan_desde(m.negocio_id);

COMMENT ON VIEW mov_visibles IS
'Movimientos que el análisis puede leer según el plan del negocio. Todo lo que
calcula indicadores lee de aquí; todo lo que escribe o corrige lee de
`movimientos`. Ver 053_historia_completa.sql.';

-- =============================================================================
-- 3. Las siete vistas de cálculo (006) leen mov_visibles
-- =============================================================================
-- CREATE OR REPLACE, no DROP: la lista de columnas no cambia, y un DROP CASCADE
-- se llevaría por delante las vistas que dependen de estas.
-- Costo actual = valor unitario de la compra más reciente por producto.
CREATE OR REPLACE VIEW v_costo_actual_producto AS
SELECT DISTINCT ON (m.negocio_id, m.producto_id)
       m.negocio_id, m.producto_id,
       m.valor_unitario AS costo_actual,
       m.fecha          AS fecha_costo
FROM mov_visibles m
WHERE m.tipo = 'compra' AND m.producto_id IS NOT NULL AND m.valor_unitario IS NOT NULL
ORDER BY m.negocio_id, m.producto_id, m.fecha DESC NULLS LAST, m.id DESC;

-- Precio actual = valor unitario de la venta más reciente por producto.
CREATE OR REPLACE VIEW v_precio_actual_producto AS
SELECT DISTINCT ON (m.negocio_id, m.producto_id)
       m.negocio_id, m.producto_id,
       m.valor_unitario AS precio_actual,
       m.fecha          AS fecha_precio
FROM mov_visibles m
WHERE m.tipo = 'venta' AND m.producto_id IS NOT NULL AND m.valor_unitario IS NOT NULL
ORDER BY m.negocio_id, m.producto_id, m.fecha DESC NULLS LAST, m.id DESC;

-- Margen = precio de venta contra costo de reposición.
CREATE OR REPLACE VIEW v_margen_producto AS
SELECT p.negocio_id, p.id AS producto_id, p.nombre_canonico,
       c.costo_actual, pr.precio_actual,
       (pr.precio_actual - c.costo_actual)                          AS margen_abs,
       round(((pr.precio_actual - c.costo_actual)
              / nullif(pr.precio_actual, 0) * 100)::numeric, 2)     AS margen_pct
FROM productos p
LEFT JOIN v_costo_actual_producto  c  ON c.negocio_id  = p.negocio_id AND c.producto_id  = p.id
LEFT JOIN v_precio_actual_producto pr ON pr.negocio_id = p.negocio_id AND pr.producto_id = p.id;

-- Deriva de costo = cuánto se movió el costo entre la primera y la última compra.
CREATE OR REPLACE VIEW v_deriva_costo AS
WITH compras AS (
    SELECT negocio_id, producto_id, valor_unitario, fecha, id,
           first_value(valor_unitario) OVER w AS costo_ini,
           last_value(valor_unitario)  OVER w AS costo_fin
    FROM mov_visibles
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
CREATE OR REPLACE VIEW v_balance_unidades AS
SELECT p.negocio_id, p.id AS producto_id,
       coalesce(sum(m.cantidad) FILTER (WHERE m.tipo = 'compra'), 0) AS compradas,
       coalesce(sum(m.cantidad) FILTER (WHERE m.tipo = 'venta'), 0)  AS vendidas,
       coalesce(sum(m.cantidad) FILTER (WHERE m.tipo = 'compra'), 0)
         - coalesce(sum(m.cantidad) FILTER (WHERE m.tipo = 'venta'), 0) AS balance
FROM productos p
LEFT JOIN mov_visibles m ON m.producto_id = p.id
GROUP BY p.negocio_id, p.id;

-- Rotación = unidades vendidas por día sobre la ventana observada, y días de
-- cobertura = cuánto dura el balance actual a ese ritmo.
CREATE OR REPLACE VIEW v_rotacion_producto AS
WITH ventas AS (
    SELECT negocio_id, producto_id,
           sum(cantidad)                                   AS unidades,
           greatest(max(fecha) - min(fecha), 1)            AS dias_ventana
    FROM mov_visibles
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
CREATE OR REPLACE VIEW v_pareto_utilidad AS
WITH util AS (
    SELECT m.negocio_id, m.producto_id,
           sum((m.valor_unitario - c.costo_actual) * m.cantidad) AS utilidad
    FROM mov_visibles m
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

-- =============================================================================
-- 4. Las funciones de análisis leen mov_visibles
-- =============================================================================
-- Reproducidas tal cual estaban (047 y 043). Único cambio: FROM movimientos ->
-- FROM mov_visibles. Las que ya leían solo de las vistas de la 006 no aparecen
-- acá: quedaron filtradas por el punto 3.

CREATE OR REPLACE FUNCTION hallazgos_generar(p_negocio_id bigint)
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
      'tipo_negocio', (SELECT coalesce(t.nombre, n.tipo)
                       FROM negocios n
                       LEFT JOIN tipos_negocio t ON t.codigo = n.tipo
                       WHERE n.id = p_negocio_id),
      'umbrales', jsonb_build_object('margen_minimo_pct', v_margen_min,
                                     'deriva_costo_alerta_pct', v_deriva_ali,
                                     'dias_cobertura_min', v_dias_cob),

      'salud', salud_negocio(p_negocio_id),
      'recomendaciones', recomendaciones_negocio(p_negocio_id),

      'periodo', (SELECT jsonb_build_object(
                    'desde', min(fecha), 'hasta', max(fecha),
                    'movimientos_venta',  count(*) FILTER (WHERE tipo = 'venta'),
                    'movimientos_compra', count(*) FILTER (WHERE tipo = 'compra'))
                  FROM mov_visibles
                  WHERE negocio_id = p_negocio_id AND fecha IS NOT NULL),

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
CREATE OR REPLACE FUNCTION recomendaciones_negocio(p_negocio_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_margen_min   numeric := coalesce((parametro(p_negocio_id,'margen_minimo_pct'))::text::numeric, 20);
    v_deriva_ali   numeric := coalesce((parametro(p_negocio_id,'deriva_costo_alerta_pct'))::text::numeric, 8);
    v_dias_cob     numeric := coalesce((parametro(p_negocio_id,'dias_cobertura_min'))::text::numeric, 7);
    v_entrega      numeric := coalesce((parametro(p_negocio_id,'dias_entrega_proveedor'))::text::numeric, 4);
    v_seguridad    numeric := coalesce((parametro(p_negocio_id,'dias_stock_seguridad'))::text::numeric, 3);
    v_lenta        numeric := coalesce((parametro(p_negocio_id,'rotacion_lenta_dias'))::text::numeric, 60);
    v_margen_alto  numeric := coalesce((parametro(p_negocio_id,'margen_alto_pct'))::text::numeric, 35);
    v_dep_prov     numeric := coalesce((parametro(p_negocio_id,'dependencia_proveedor_pct'))::text::numeric, 50);
    v_pri_alta     numeric := coalesce((parametro(p_negocio_id,'prioridad_alta_pct'))::text::numeric, 2);
    v_pri_media    numeric := coalesce((parametro(p_negocio_id,'prioridad_media_pct'))::text::numeric, 0.5);
    v_meses        numeric;
    v_base_mes     numeric;   -- lo que mueve el negocio en un mes
    v_out          jsonb;
BEGIN
    -- Ventana real de los datos. Todo lo "por mes" se escala con esto, así que
    -- un negocio que cargó 15 días no ve cifras infladas ni desinfladas.
    SELECT greatest((max(fecha) - min(fecha))::numeric / 30.0, 1) INTO v_meses
    FROM mov_visibles WHERE negocio_id = p_negocio_id AND fecha IS NOT NULL;
    v_meses := coalesce(v_meses, 1);

    SELECT greatest(coalesce(sum(valor_total) FILTER (WHERE tipo = 'venta'),
                             sum(valor_total) FILTER (WHERE tipo = 'compra'), 0) / v_meses, 1)
      INTO v_base_mes
    FROM mov_visibles WHERE negocio_id = p_negocio_id;

    WITH
    -- Unidades compradas y vendidas por producto.
    base AS (
        SELECT m.producto_id,
               sum(m.cantidad) FILTER (WHERE m.tipo = 'compra') AS u_compradas,
               sum(m.cantidad) FILTER (WHERE m.tipo = 'venta')  AS u_vendidas
        FROM mov_visibles m
        WHERE m.negocio_id = p_negocio_id AND m.producto_id IS NOT NULL
        GROUP BY 1
    ),
    -- Precio promedio por proveedor, para saber si hay dónde comprar más barato.
    por_proveedor AS (
        SELECT m.producto_id,
               nullif(btrim(coalesce(m.raw ->> 'proveedor', '')), '') AS proveedor,
               sum(m.cantidad)                                        AS u,
               sum(m.valor_total) / nullif(sum(m.cantidad), 0)        AS precio_prom
        FROM mov_visibles m
        WHERE m.negocio_id = p_negocio_id AND m.tipo = 'compra'
          AND m.producto_id IS NOT NULL AND m.cantidad > 0 AND m.valor_total > 0
        GROUP BY 1, 2
    ),
    alternativa AS (
        SELECT producto_id,
               (array_agg(proveedor ORDER BY precio_prom))[1] AS prov_barato,
               round(min(precio_prom))                        AS precio_mejor,
               round(sum(u * precio_prom) / nullif(sum(u), 0)) AS precio_pagado,
               sum(u)                                         AS u_total
        FROM por_proveedor
        WHERE proveedor IS NOT NULL
        GROUP BY 1
        HAVING count(DISTINCT proveedor) > 1
    ),

    -- R1. El costo subió -----------------------------------------------------
    -- Las opciones se arman con unnest + agregado, no con jsonb_strip_nulls:
    -- strip_nulls solo borra campos NULL de OBJETOS, no elementos de un array,
    -- así que una opción que no aplica dejaría un `null` suelto en la lista.
    r_costo AS (
        SELECT 'costo' AS regla, '📈' AS icono, p.nombre_canonico AS titulo,
               round(coalesce(d.costo_fin - d.costo_ini, 0)
                     * coalesce(b.u_compradas, 0) / v_meses) AS impacto_mes,
               CASE WHEN round(coalesce(d.costo_fin - d.costo_ini, 0)
                               * coalesce(b.u_compradas, 0) / v_meses) > 0
                    THEN format('Al ritmo que lo comprás, son unos $%s más al mes.',
                                miles(round((d.costo_fin - d.costo_ini)
                                            * b.u_compradas / v_meses)))
                    ELSE '' END AS impacto_txt,
               format('El costo pasó de $%s a $%s: subió %s%% desde tu primera compra.',
                      miles(d.costo_ini), miles(d.costo_fin), fmt_decimal(d.deriva_pct))
               || CASE WHEN mp.precio_actual IS NOT NULL AND mp.precio_actual > 0
                       THEN format(' Con tu precio de venta actual el margen te queda en %s%%.',
                                   fmt_decimal(mp.margen_pct))
                       ELSE '' END AS problema,
               (SELECT coalesce(jsonb_agg(x), '[]'::jsonb) FROM unnest(ARRAY[
                  'Negociá el precio con tu proveedor antes de la próxima compra.'::text,
                  CASE WHEN a.prov_barato IS NOT NULL AND a.precio_mejor < d.costo_fin
                       THEN format('Comprale a %s, que te lo dejó a $%s.',
                                   a.prov_barato, miles(a.precio_mejor)) END,
                  CASE WHEN mp.precio_actual IS NOT NULL AND mp.precio_actual > 0
                            AND mp.margen_pct < v_margen_min
                       THEN format('Si no conseguís mejor precio, subí el precio de venta a $%s para volver a un margen de %s%%.',
                                   miles(round(d.costo_fin / nullif(1 - v_margen_min/100, 0))),
                                   fmt_decimal(v_margen_min)) END
                ]) AS x WHERE x IS NOT NULL) AS opciones
        FROM v_deriva_costo d
        JOIN productos p ON p.id = d.producto_id
        LEFT JOIN base b ON b.producto_id = d.producto_id
        LEFT JOIN alternativa a ON a.producto_id = d.producto_id
        LEFT JOIN v_margen_producto mp
               ON mp.producto_id = d.producto_id AND mp.negocio_id = d.negocio_id
        WHERE d.negocio_id = p_negocio_id AND d.deriva_pct >= v_deriva_ali
    ),

    -- R2. Estás pagando más de lo que ya conseguiste ------------------------
    r_proveedor AS (
        SELECT 'proveedor' AS regla, '🧾' AS icono, p.nombre_canonico AS titulo,
               round((a.precio_pagado - a.precio_mejor) * a.u_total / v_meses) AS impacto_mes,
               format('Estás dejando ir unos $%s al mes por comprarlo más caro de lo que ya lo conseguiste.',
                      miles(round((a.precio_pagado - a.precio_mejor) * a.u_total / v_meses))) AS impacto_txt,
               format('En promedio lo pagás a $%s, pero %s te lo dejó a $%s.',
                      miles(a.precio_pagado), a.prov_barato, miles(a.precio_mejor)) AS problema,
               jsonb_build_array(
                 format('Concentrá la compra de este producto en %s.', a.prov_barato),
                 'Usá ese precio como referencia para negociar con los demás.') AS opciones
        FROM alternativa a
        JOIN productos p ON p.id = a.producto_id
        WHERE a.precio_pagado > a.precio_mejor * 1.05
    ),

    -- R3. Margen por debajo del mínimo ---------------------------------------
    r_margen AS (
        SELECT 'margen' AS regla, '⚠️' AS icono, mp.nombre_canonico AS titulo,
               round(greatest(round(mp.costo_actual / nullif(1 - v_margen_min/100, 0))
                              - mp.precio_actual, 0)
                     * coalesce(b.u_vendidas, 0) / v_meses) AS impacto_mes,
               CASE WHEN coalesce(b.u_vendidas, 0) > 0
                    THEN format('Son unos $%s al mes que no estás ganando.',
                                miles(round(greatest(round(mp.costo_actual / nullif(1 - v_margen_min/100, 0))
                                                     - mp.precio_actual, 0)
                                            * b.u_vendidas / v_meses)))
                    ELSE '' END AS impacto_txt,
               format('Lo vendés a $%s y te cuesta $%s: te deja %s%% de margen, por debajo del %s%% que deberías sostener.',
                      miles(mp.precio_actual), miles(mp.costo_actual),
                      fmt_decimal(mp.margen_pct), fmt_decimal(v_margen_min)) AS problema,
               jsonb_build_array(
                 format('Subilo a $%s y quedás en %s%% de margen.',
                        miles(round(mp.costo_actual / nullif(1 - v_margen_min/100, 0))),
                        fmt_decimal(v_margen_min)),
                 'Si no podés subir el precio, negociá el costo o buscá otra marca equivalente.') AS opciones
        FROM v_margen_producto mp
        LEFT JOIN base b ON b.producto_id = mp.producto_id
        WHERE mp.negocio_id = p_negocio_id
          AND mp.precio_actual IS NOT NULL AND mp.precio_actual > 0
          AND mp.costo_actual IS NOT NULL
          AND mp.margen_pct < v_margen_min
    ),

    -- R4. Se agota, y cuánto comprar ----------------------------------------
    -- La cantidad es la del ciclo completo: lo que se vende mientras el
    -- proveedor entrega, más el colchón. Es la cuenta que un tendero no hace y
    -- que decide entre quedarse sin producto o dormir la plata.
    r_agota AS (
        SELECT 'agota' AS regla, '🕐' AS icono, p.nombre_canonico AS titulo,
               round(r.unidades_por_dia * v_entrega
                     * coalesce(mp.precio_actual, 0)) AS impacto_mes,
               CASE WHEN coalesce(mp.precio_actual, 0) > 0
                    THEN format('Si te quedás sin producto, son unos $%s que dejás de vender mientras llega el pedido.',
                                miles(round(r.unidades_por_dia * v_entrega * mp.precio_actual)))
                    ELSE '' END AS impacto_txt,
               -- Cobertura negativa = vendió más unidades de las que registró
               -- comprando. Decir "te alcanza para -95 días" no significa nada;
               -- lo que pasa es que ya no queda o falta cargar compras.
               CASE WHEN r.dias_cobertura < 0
                    THEN format('Por lo que cargaste ya no te queda: vendiste más de lo que registraste comprando. Vendés %s por día.',
                                unidades_es(r.unidades_por_dia))
                    ELSE format('Te alcanza para %s días y vendés %s por día.',
                                fmt_decimal(r.dias_cobertura),
                                unidades_es(r.unidades_por_dia))
               END AS problema,
               jsonb_build_array(
                 format('Pedí %s: es lo que vendés en los %s días que demora el proveedor más %s días de colchón.',
                        unidades_es(ceil(r.unidades_por_dia * (v_entrega + v_seguridad))),
                        fmt_decimal(v_entrega), fmt_decimal(v_seguridad)),
                 'Si el proveedor demora más de lo normal, pedí antes, no más cantidad.') AS opciones
        FROM v_rotacion_producto r
        JOIN productos p ON p.id = r.producto_id
        LEFT JOIN v_margen_producto mp
               ON mp.producto_id = r.producto_id AND mp.negocio_id = r.negocio_id
        WHERE r.negocio_id = p_negocio_id
          AND r.dias_cobertura IS NOT NULL AND r.dias_cobertura < v_dias_cob
          AND r.unidades_por_dia > 0
    ),

    -- R5. Plata quieta: mucho inventario para lo que rota --------------------
    r_quieto AS (
        SELECT 'quieto' AS regla, CASE WHEN mp.margen_pct >= v_margen_alto THEN '💰' ELSE '📦' END AS icono,
               p.nombre_canonico AS titulo,
               round(bal.balance * coalesce(mp.costo_actual, 0)) AS impacto_mes,
               CASE WHEN coalesce(mp.costo_actual, 0) > 0
                    THEN format('Tenés $%s inmovilizados en esa mercancía.',
                                miles(round(bal.balance * mp.costo_actual)))
                    ELSE '' END AS impacto_txt,
               format('Tenés inventario para %s días y solo vendés %s unidades por día.',
                      fmt_decimal(r.dias_cobertura), fmt_decimal(r.unidades_por_dia)) AS problema,
               CASE WHEN mp.margen_pct >= v_margen_alto
                    THEN jsonb_build_array(
                           format('Te deja %s%% de margen: empujalo con una promoción o ponelo a la vista, en vez de rematarlo.',
                                  fmt_decimal(mp.margen_pct)),
                           'No vuelvas a comprarlo hasta bajar lo que tenés.')
                    ELSE jsonb_build_array(
                           'No vuelvas a comprarlo hasta agotar lo que tenés.',
                           'Si sigue sin moverse, sacalo con descuento antes de que se venza o pase de moda.')
               END AS opciones
        FROM v_rotacion_producto r
        JOIN productos p ON p.id = r.producto_id
        JOIN v_balance_unidades bal
          ON bal.producto_id = r.producto_id AND bal.negocio_id = r.negocio_id
        LEFT JOIN v_margen_producto mp
               ON mp.producto_id = r.producto_id AND mp.negocio_id = r.negocio_id
        WHERE r.negocio_id = p_negocio_id
          AND r.dias_cobertura IS NOT NULL AND r.dias_cobertura > v_lenta
          AND bal.balance > 0
    ),

    -- R6. Un solo proveedor concentra las compras ----------------------------
    gasto_prov AS (
        SELECT nullif(btrim(coalesce(m.raw ->> 'proveedor', '')), '') AS proveedor,
               sum(m.valor_total) AS gasto
        FROM mov_visibles m
        WHERE m.negocio_id = p_negocio_id AND m.tipo = 'compra'
        GROUP BY 1
    ),
    r_dependencia AS (
        SELECT 'dependencia' AS regla, '🔎' AS icono, 'Dependés de un solo proveedor' AS titulo,
               0::numeric AS impacto_mes, '' AS impacto_txt,
               format('%s concentra el %s%% de todo lo que comprás ($%s).',
                      g.proveedor,
                      fmt_decimal(round(g.gasto * 100.0 / nullif(t.total, 0), 1)),
                      miles(round(g.gasto))) AS problema,
               jsonb_build_array(
                 'Conseguí un segundo proveedor para los productos que más te pesan, aunque le compres poco.',
                 'Con dos precios en la mano tenés con qué negociar; con uno solo, aceptás lo que te digan.') AS opciones
        FROM gasto_prov g,
             LATERAL (SELECT sum(gasto) AS total FROM gasto_prov) t
        WHERE g.proveedor IS NOT NULL AND t.total > 0
          AND g.gasto * 100.0 / t.total >= v_dep_prov
    ),

    todas AS (
        SELECT * FROM r_costo      UNION ALL
        SELECT * FROM r_proveedor  UNION ALL
        SELECT * FROM r_margen     UNION ALL
        SELECT * FROM r_agota      UNION ALL
        SELECT * FROM r_quieto     UNION ALL
        SELECT * FROM r_dependencia
    ),
    -- La prioridad es el impacto mensual medido contra lo que mueve el negocio.
    -- La dependencia de proveedor no tiene impacto calculable y entra fija en
    -- media: es un riesgo, no una pérdida que ya esté ocurriendo.
    priorizadas AS (
        SELECT icono, titulo, problema, opciones, impacto_txt,
               coalesce(impacto_mes, 0) AS impacto_mes,
               CASE WHEN regla = 'dependencia' THEN 'media'
                    WHEN coalesce(impacto_mes,0) * 100.0 / v_base_mes >= v_pri_alta  THEN 'alta'
                    WHEN coalesce(impacto_mes,0) * 100.0 / v_base_mes >= v_pri_media THEN 'media'
                    ELSE 'baja' END AS prioridad,
               -- El tope por regla: lo peor de cada frente, no el ranking de
               -- pesos, que se llena con la regla que más productos toca.
               row_number() OVER (PARTITION BY regla
                                  ORDER BY coalesce(impacto_mes, 0) DESC) AS rn
        FROM todas
        WHERE coalesce(titulo, '') <> ''
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'icono', icono, 'prioridad', prioridad, 'titulo', titulo,
             'problema', problema,
             'impacto', coalesce(impacto_txt, ''),
             'impacto_mes', impacto_mes,
             'opciones', opciones)
             ORDER BY CASE prioridad WHEN 'alta' THEN 1 WHEN 'media' THEN 2 ELSE 3 END,
                      impacto_mes DESC), '[]'::jsonb)
      INTO v_out
    FROM (SELECT * FROM priorizadas
           WHERE rn <= 2
           ORDER BY CASE prioridad WHEN 'alta' THEN 1 WHEN 'media' THEN 2 ELSE 3 END,
                    impacto_mes DESC
           LIMIT 8) s;

    RETURN v_out;
END;
$$;
CREATE OR REPLACE FUNCTION salud_negocio(p_negocio_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
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
    v_indice     numeric;
    v_mitad      date;
    v_desde      date;
    v_hasta      date;
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

    SELECT round(avg(n)) INTO v_indice
    FROM unnest(ARRAY[v_ventas, v_margenes, v_inventario, v_compras, v_riesgos]) AS n
    WHERE n IS NOT NULL;

    IF v_indice IS NULL THEN
        RETURN NULL;   -- sin datos suficientes, no se dibuja el semáforo
    END IF;

    RETURN jsonb_strip_nulls(jsonb_build_object(
        'ventas', v_ventas, 'margenes', v_margenes, 'inventario', v_inventario,
        'compras', v_compras, 'riesgos', v_riesgos, 'indice', v_indice));
END;
$$;
CREATE OR REPLACE FUNCTION hallazgos_compras(p_negocio_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_deriva_ali numeric := (parametro(p_negocio_id, 'deriva_costo_alerta_pct'))::text::numeric;
    v_out jsonb;
BEGIN
    WITH compras AS (
        SELECT m.*, coalesce(p.nombre_canonico, m.raw ->> 'descripcion',
                             m.raw ->> 'producto', 'sin nombre') AS etiqueta,
               nullif(btrim(coalesce(m.raw ->> 'proveedor', '')), '') AS proveedor
        FROM mov_visibles m
        LEFT JOIN productos p ON p.id = m.producto_id
        WHERE m.negocio_id = p_negocio_id AND m.tipo = 'compra'
    ),
    gasto AS (SELECT sum(valor_total) AS total FROM compras)
    SELECT jsonb_build_object(
      'negocio_id', p_negocio_id,
      'generado_en', now(),

      'periodo', (SELECT jsonb_build_object(
                    'desde', min(fecha), 'hasta', max(fecha),
                    'movimientos_compra', count(*))
                  FROM compras WHERE fecha IS NOT NULL),

      'resumen', (SELECT jsonb_build_object(
                    'productos',   count(DISTINCT etiqueta),
                    'gasto_total', round(coalesce(sum(valor_total), 0)),
                    'proveedores', count(DISTINCT proveedor) FILTER (WHERE proveedor IS NOT NULL),
                    'documentos',  count(DISTINCT documento_id))
                  FROM compras),

      -- Dónde se va la plata: top de gasto por producto con su participación.
      'gasto_producto', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                           'producto', etiqueta, 'gasto', gasto_p,
                           'unidades', unidades, 'pct_gasto', pct) ORDER BY gasto_p DESC), '[]')
                         FROM (SELECT etiqueta,
                                      round(sum(valor_total)) AS gasto_p,
                                      round(sum(cantidad))    AS unidades,
                                      round((sum(valor_total) * 100.0
                                             / nullif((SELECT total FROM gasto), 0))::numeric, 1) AS pct
                               FROM compras GROUP BY etiqueta
                               ORDER BY sum(valor_total) DESC NULLS LAST LIMIT 8) t),

      -- Costo al alza: misma vista y mismo umbral que el análisis de ventas.
      'deriva_costo', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                         'producto_id', d.producto_id, 'producto', p.nombre_canonico,
                         'costo_ini', d.costo_ini, 'costo_fin', d.costo_fin,
                         'deriva_pct', d.deriva_pct) ORDER BY abs(d.deriva_pct) DESC), '[]')
                       FROM v_deriva_costo d JOIN productos p ON p.id = d.producto_id
                       WHERE d.negocio_id = p_negocio_id
                         AND abs(d.deriva_pct) >= v_deriva_ali),

      -- Precios muy distintos por el mismo producto: margen para negociar.
      'precio_disperso', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                            'producto', etiqueta, 'precio_min', pmin,
                            'precio_max', pmax, 'dispersion_pct', disp)
                            ORDER BY disp DESC), '[]')
                          FROM (SELECT etiqueta,
                                       round(min(valor_unitario)) AS pmin,
                                       round(max(valor_unitario)) AS pmax,
                                       round(((max(valor_unitario) - min(valor_unitario))
                                              / nullif(min(valor_unitario), 0) * 100)::numeric, 1) AS disp
                                FROM compras WHERE valor_unitario > 0
                                GROUP BY etiqueta
                                HAVING count(*) > 1
                                   AND (max(valor_unitario) - min(valor_unitario))
                                       / nullif(min(valor_unitario), 0) >= 0.10
                                ORDER BY disp DESC LIMIT 8) t),

      -- Peso de cada proveedor en el gasto.
      'proveedores', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'proveedor', coalesce(proveedor, 'sin dato'),
                        'gasto', gasto_v, 'pct_gasto', pct) ORDER BY gasto_v DESC), '[]')
                      FROM (SELECT proveedor, round(sum(valor_total)) AS gasto_v,
                                   round((sum(valor_total) * 100.0
                                          / nullif((SELECT total FROM gasto), 0))::numeric, 1) AS pct
                            FROM compras GROUP BY proveedor
                            ORDER BY sum(valor_total) DESC NULLS LAST LIMIT 6) t),

      -- Comprado que no registra ni una venta: plata quieta. Solo tiene sentido
      -- si el negocio también carga ventas; si no hay ventas, va vacío y el
      -- prompt no arma la sección.
      'sin_venta', CASE WHEN EXISTS (SELECT 1 FROM mov_visibles
                                     WHERE negocio_id = p_negocio_id AND tipo = 'venta')
                   THEN (SELECT coalesce(jsonb_agg(jsonb_build_object(
                           'producto', etiqueta, 'unidades', unidades, 'gasto', gasto_p)
                           ORDER BY gasto_p DESC), '[]')
                         FROM (SELECT c.etiqueta, round(sum(c.cantidad)) AS unidades,
                                      round(sum(c.valor_total)) AS gasto_p
                               FROM compras c
                               WHERE c.producto_id IS NOT NULL
                                 AND NOT EXISTS (SELECT 1 FROM mov_visibles v
                                                 WHERE v.negocio_id = p_negocio_id
                                                   AND v.tipo = 'venta'
                                                   AND v.producto_id = c.producto_id)
                               GROUP BY c.etiqueta
                               ORDER BY sum(c.valor_total) DESC LIMIT 8) t)
                   ELSE '[]'::jsonb END
    ) INTO v_out;

    RETURN v_out;
END;
$$;

-- =============================================================================
-- 4b. Las dos compuertas del router que preguntan "¿puedo analizar ya?"
-- =============================================================================
-- Estas dos leen `movimientos` para decidir si el negocio tiene compras
-- suficientes como para correr `mercado_compras` sin subir nada nuevo. Es una
-- pregunta de ANÁLISIS, no de escritura, y hasta ahora coincidía con lo que el
-- informe iba a ver porque las filas viejas no existían. Desde el punto 1 sí
-- existen, así que sin este cambio el bot ofrecería "generá con lo que tengo",
-- y `mercado_compras_bienvenida` llegaría a anunciar un gasto y un periodo que
-- el informe después no usa. Las dos pasan a mirar por la misma ventana que el
-- análisis.
--
-- Se reproduce `router_procesar_mensaje` entero —de la 051, que es la versión
-- viva— por una sola línea. Es la novena copia íntegra de esta función, y es
-- exactamente la deuda que la fase A' (router modular) viene a cerrar.

CREATE OR REPLACE FUNCTION mercado_compras_bienvenida(p_negocio_id bigint,
                                                      p_chat_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v record;
BEGIN
    SELECT count(DISTINCT m.documento_id)                              AS documentos,
           count(DISTINCT coalesce(p.nombre_canonico,
                 m.raw ->> 'descripcion', m.raw ->> 'producto'))       AS productos,
           round(coalesce(sum(m.valor_total), 0))                      AS gasto,
           min(m.fecha) AS desde, max(m.fecha) AS hasta
    INTO v
    FROM mov_visibles m
    LEFT JOIN productos p ON p.id = m.producto_id
    WHERE m.negocio_id = p_negocio_id AND m.tipo = 'compra';

    IF coalesce(v.documentos, 0) = 0 THEN
        RETURN router_respuesta(p_chat_id, 'mercado.pedir_facturas');
    END IF;

    RETURN router_respuesta(p_chat_id, 'mercado.datos_previos', jsonb_build_object(
        'documentos', v.documentos,
        'productos',  v.productos,
        'gasto',      '$' || miles(v.gasto),
        'rango',      coalesce(' ' || nullif(periodo_es(v.desde, v.hasta), ''), '')));
END;
$$;

CREATE OR REPLACE FUNCTION router_procesar_mensaje(p_evento jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_usuario_id bigint;
    v_chat_id    bigint  := (p_evento #>> '{chat,id}')::bigint;
    v_texto      text    := btrim(coalesce(p_evento ->> 'texto', ''));
    v_cmd        text;
    v_svc        text;          -- código que llegó por botón (svc:<codigo>)
    v_mod        text;          -- código de módulo (mod:/modayuda:)
    v_tip        text;          -- >>> 046: naturaleza del negocio (tipo:<codigo>)
    v_arg        text;          -- resto del mensaje después del comando
    v_tiene_doc  boolean := coalesce((p_evento ->> 'tiene_documento')::boolean, false);
    v_sesion     record;
    v_negocio_id bigint;
    v_autoriz    boolean;
    v_rol        rol_usuario;
    v_servicio   record;
    v_modulo     record;
    v_n_serv     int;
    v_consulta   boolean;
    v_ejec_id    bigint;
    v_nueva_ses  bigint;
    v_titulo     text;
BEGIN
    -- El primer token y el resto. Se parte por espacio EN BLANCO, no por ' ':
    -- un "/saber" seguido de salto de línea es la forma natural de enseñarle
    -- algo largo, y con split_part(' ') el comando se comía el texto entero.
    v_cmd := lower(coalesce(substring(v_texto FROM '^\S+'), ''));
    v_arg := btrim(coalesce(substring(v_texto FROM '^\S+\s+(.*)$'), ''));
    IF v_texto LIKE 'svc:%' THEN
        v_svc := substring(v_texto FROM 5);
        v_cmd := 'svc';
    ELSIF v_texto LIKE 'mod:%' THEN
        v_mod := substring(v_texto FROM 5);
        v_cmd := 'mod';
    ELSIF v_texto LIKE 'modayuda:%' THEN
        v_mod := substring(v_texto FROM 10);
        v_cmd := 'modayuda';
    ELSIF v_texto LIKE 'tipo:%' THEN
        v_tip := substring(v_texto FROM 6);
        v_cmd := 'tipo';
    ELSIF v_texto LIKE 'acepto:%' THEN
        -- >>> 051: 'acepto:<mensaje original>' — el consentimiento se lleva
        -- puesto el paso que lo disparó para poder retomarlo.
        v_arg := btrim(substring(v_texto FROM 8));
        v_cmd := 'acepto';
    END IF;

    v_usuario_id := usuario_de_canal('telegram', p_evento);
    SELECT negocio_id, autorizacion_datos, rol
      INTO v_negocio_id, v_autoriz, v_rol
    FROM usuarios WHERE id = v_usuario_id;

    -- Solo los de archivos: los de texto no se eligen de una lista.
    SELECT count(*) INTO v_n_serv
    FROM servicios WHERE activo AND entrada = 'archivos';
    SELECT EXISTS (SELECT 1 FROM servicios WHERE activo AND entrada = 'texto'
                     AND codigo = 'consulta') INTO v_consulta;

    -- ---- Comandos de admin -------------------------------------------------
    IF v_cmd IN ('/salud','/embudo','/fallas','/consumo','/matching','/admin') THEN
        IF v_rol <> 'admin' THEN
            RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
        END IF;
        RETURN router_respuesta(v_chat_id, admin_reporte(v_cmd));
    END IF;

    SELECT * INTO v_sesion FROM sesiones
    WHERE usuario_id = v_usuario_id AND cerrada_en IS NULL
    ORDER BY id DESC LIMIT 1;
    IF v_sesion.id IS NOT NULL THEN
        UPDATE sesiones SET ultima_actividad = now() WHERE id = v_sesion.id;
    END IF;

    -- ---- Informativos: accesibles incluso sin autorizar --------------------
    IF v_cmd IN ('/start','/help','/ayuda') THEN
        RETURN router_respuesta(v_chat_id, 'sistema.bienvenida');   -- >>> 046
    END IF;
    IF v_cmd = '/comofunciona' THEN
        RETURN router_respuesta(v_chat_id, 'sistema.como_funciona');
    END IF;
    IF v_cmd = '/privacidad' THEN
        RETURN router_respuesta(v_chat_id, 'sistema.privacidad');
    END IF;

    -- ---- Módulos: son un menú, no tocan un solo dato -----------------------
    -- >>> 051: van ANTES del consentimiento a propósito. Mirar la lista de lo
    -- que el asistente sabe hacer no requiere autorizar nada; el permiso se
    -- pide justo cuando se elige una opción, que es cuando se van a entregar
    -- datos del negocio. Pedirlo antes es pedirlo a ciegas.
    IF v_cmd = 'mod' THEN
        SELECT * INTO v_modulo FROM modulos WHERE activo AND codigo = v_mod;
        IF v_modulo.codigo IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.bienvenida');
        END IF;
        RETURN router_respuesta(v_chat_id, 'sistema.modulo',
                 jsonb_build_object('titular', v_modulo.titular),
                 teclado_modulo(v_modulo.codigo));
    END IF;

    IF v_cmd = 'modayuda' THEN
        SELECT * INTO v_modulo FROM modulos WHERE activo AND codigo = v_mod;
        IF v_modulo.codigo IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.bienvenida');
        END IF;
        RETURN router_respuesta(v_chat_id, 'sistema.modulo_ayuda',
                 jsonb_build_object('ayuda', v_modulo.ayuda),
                 teclado_modulo(v_modulo.codigo));
    END IF;

    -- ---- >>> 051: "Acepto" con memoria de lo que se estaba haciendo --------
    -- El botón del consentimiento manda 'acepto:<lo que el usuario había
    -- tocado>'. Se registra el permiso y se vuelve a despachar ESE mensaje, ya
    -- autorizado: el usuario cae exactamente donde iba, no en la bienvenida.
    -- No hay recursión infinita porque la autorización ya quedó en true.
    IF v_cmd = 'acepto' OR
       (NOT v_autoriz AND lower(v_texto) IN ('acepto','autorizo','si','sí','ok','dale')) THEN
        UPDATE usuarios SET autorizacion_datos = true, autorizacion_fecha = now()
        WHERE id = v_usuario_id;
        IF v_cmd = 'acepto' AND v_arg <> '' THEN
            RETURN router_procesar_mensaje(
                     p_evento || jsonb_build_object('texto', v_arg));
        END IF;
        RETURN router_respuesta(v_chat_id, 'sistema.bienvenida');
    END IF;

    -- ---- Consentimiento de datos (una sola vez) ----------------------------
    -- Lo que el usuario tocó viaja en el botón para poder retomarlo al aceptar.
    IF NOT v_autoriz THEN
        RETURN router_respuesta(v_chat_id, 'sistema.consentimiento',
                 jsonb_build_object('meses',
                   coalesce((parametro(NULL, 'plan_free_meses_historia'))::text, '3')),
                 teclado_consentimiento(v_texto));
    END IF;

    -- ---- >>> 046: naturaleza del negocio -----------------------------------
    -- Se contesta una vez y sigue el camino que estaba interrumpido. Un botón
    -- viejo del historial vuelve a guardar lo mismo: es idempotente.
    IF v_cmd = 'tipo' THEN
        IF v_negocio_id IS NULL
           OR NOT EXISTS (SELECT 1 FROM tipos_negocio WHERE activo AND codigo = v_tip) THEN
            RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
        END IF;
        UPDATE negocios SET tipo = v_tip WHERE id = v_negocio_id;

        IF v_sesion.id IS NOT NULL AND v_sesion.servicio_codigo IS NOT NULL THEN
            RETURN router_arranque_servicio(v_negocio_id, v_chat_id,
                                            v_sesion.servicio_codigo);
        END IF;
        RETURN router_respuesta(v_chat_id, 'sistema.bienvenida');
    END IF;

    -- ---- /portal: el enlace de un solo uso ---------------------------------
    IF v_cmd IN ('/portal','/web') THEN
        RETURN router_portal(v_usuario_id, v_chat_id);
    END IF;

    -- Plan, consumo del mes y enlace de pago si el operador lo configuró.
    IF v_cmd = '/plan' THEN
        RETURN router_plan(v_negocio_id, v_chat_id);
    END IF;

    -- ---- /saber: el dueño le enseña algo al bot ----------------------------
    IF v_cmd = '/saber' THEN
        IF v_negocio_id IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
        END IF;
        IF v_arg = '' THEN
            RETURN router_respuesta(v_chat_id, 'conocimiento.saber_vacio');
        END IF;
        v_titulo := btrim(split_part(v_arg, '.', 1));
        IF char_length(v_titulo) > 80 OR v_titulo = '' THEN
            v_titulo := btrim(left(v_arg, 80));
        END IF;
        PERFORM conocimiento_guardar(v_negocio_id, 'faq', v_titulo, v_arg,
                                     NULL, '{}'::jsonb, 'chat', v_usuario_id);
        RETURN router_respuesta(v_chat_id, 'conocimiento.guardado',
                 jsonb_build_object('titulo', v_titulo));
    END IF;

    -- ---- Cancelar ----------------------------------------------------------
    IF v_cmd IN ('/cancelar','/cancel') THEN
        IF v_sesion.id IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.sin_sesion');
        END IF;
        UPDATE sesiones SET estado = 'expirada', cerrada_en = now()
        WHERE usuario_id = v_usuario_id AND cerrada_en IS NULL;
        RETURN router_respuesta(v_chat_id, 'sesion.cancelada');
    END IF;

    -- ---- /nueva ------------------------------------------------------------
    IF v_cmd = '/nueva' THEN
        UPDATE sesiones SET estado = 'expirada', cerrada_en = now()
        WHERE usuario_id = v_usuario_id AND cerrada_en IS NULL;

        IF v_n_serv = 1 THEN
            SELECT * INTO v_servicio FROM servicios
            WHERE activo AND entrada = 'archivos' LIMIT 1;
            INSERT INTO sesiones (usuario_id, negocio_id, servicio_codigo, estado, paso)
            VALUES (v_usuario_id, v_negocio_id, v_servicio.codigo, 'recibiendo', 'cargar_archivos');
            RETURN router_arranque_servicio(v_negocio_id, v_chat_id, v_servicio.codigo);
        END IF;

        INSERT INTO sesiones (usuario_id, negocio_id, estado, paso)
        VALUES (v_usuario_id, v_negocio_id, 'intake', 'elegir_servicio');
        RETURN router_respuesta(v_chat_id, 'sistema.elegir_servicio',
                 '{}'::jsonb, teclado_servicios());
    END IF;

    -- ---- Servicio elegido desde el menú (045) ------------------------------
    IF v_cmd = 'svc' AND (v_sesion.id IS NULL OR v_sesion.estado = 'intake') THEN
        SELECT * INTO v_servicio FROM servicios
        WHERE activo AND entrada = 'archivos' AND codigo = v_svc;

        IF v_servicio.codigo IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.servicio_no_reconocido',
                     '{}'::jsonb, teclado_servicios());
        END IF;

        IF v_sesion.id IS NULL THEN
            INSERT INTO sesiones (usuario_id, negocio_id, servicio_codigo, estado, paso)
            VALUES (v_usuario_id, v_negocio_id, v_servicio.codigo,
                    'recibiendo', 'cargar_archivos');
        ELSE
            UPDATE sesiones SET servicio_codigo = v_servicio.codigo,
                   estado = 'recibiendo', paso = 'cargar_archivos'
            WHERE id = v_sesion.id;
        END IF;

        RETURN router_arranque_servicio(v_negocio_id, v_chat_id, v_servicio.codigo);
    END IF;

    -- ---- Sin sesión abierta ------------------------------------------------
    IF v_sesion.id IS NULL THEN
        IF v_tiene_doc AND v_n_serv = 1 THEN
            SELECT * INTO v_servicio FROM servicios
            WHERE activo AND entrada = 'archivos' LIMIT 1;
            INSERT INTO sesiones (usuario_id, negocio_id, servicio_codigo, estado, paso)
            VALUES (v_usuario_id, v_negocio_id, v_servicio.codigo, 'recibiendo', 'cargar_archivos')
            RETURNING id INTO v_nueva_ses;
            RETURN router_respuesta(v_chat_id, 'sistema.archivo_sin_sesion',
                     jsonb_build_object('servicio', v_servicio.nombre), NULL,
                     jsonb_build_array(jsonb_build_object(
                       'tipo','ingerir','sesion_id', v_nueva_ses)));
        END IF;
        IF v_tiene_doc THEN
            RETURN router_respuesta(v_chat_id, 'sistema.elegir_servicio',
                     '{}'::jsonb, teclado_servicios());
        END IF;

        -- Texto libre = pregunta. Va último a propósito: cualquier cosa que
        -- empiece con '/' es un comando que no existe, no una pregunta, y un
        -- 'svc:' es un botón rancio del historial.
        IF v_consulta AND v_texto <> '' AND left(v_texto, 1) <> '/' AND v_cmd <> 'svc' THEN
            RETURN consulta_iniciar(v_usuario_id, v_negocio_id, v_chat_id, v_texto);
        END IF;

        RETURN router_respuesta(v_chat_id, 'sistema.sin_sesion');
    END IF;

    -- ---- Ya se está ejecutando: nada de disparar una segunda corrida -------
    IF v_sesion.estado = 'procesando' THEN
        RETURN router_respuesta(v_chat_id, 'ejecucion.ya_en_curso');
    END IF;

    -- ---- Intake: elegir servicio ------------------------------------------
    -- Queda para el nombre escrito a mano y para el archivo mandado antes de
    -- elegir; el botón `svc:` ya lo resolvió el bloque de arriba.
    IF v_sesion.estado = 'intake' AND v_sesion.paso = 'elegir_servicio' THEN
        IF v_tiene_doc AND v_n_serv = 1 THEN
            SELECT * INTO v_servicio FROM servicios
            WHERE activo AND entrada = 'archivos' LIMIT 1;
        ELSE
            SELECT * INTO v_servicio FROM servicios
            WHERE activo AND entrada = 'archivos'
              AND (norm_texto(nombre) LIKE '%'||norm_texto(v_texto)||'%'
                   OR norm_texto(v_texto) LIKE '%'||norm_texto(nombre)||'%'
                   OR codigo = lower(v_texto))
            ORDER BY orden LIMIT 1;
        END IF;

        IF v_servicio.codigo IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.servicio_no_reconocido',
                     '{}'::jsonb, teclado_servicios());
        END IF;

        UPDATE sesiones SET servicio_codigo = v_servicio.codigo, estado = 'recibiendo',
               paso = 'cargar_archivos' WHERE id = v_sesion.id;

        IF v_tiene_doc THEN
            RETURN router_respuesta(v_chat_id, NULL, NULL, NULL,
                     jsonb_build_array(jsonb_build_object(
                       'tipo','ingerir','sesion_id', v_sesion.id)));
        END IF;

        RETURN router_arranque_servicio(v_negocio_id, v_chat_id, v_servicio.codigo);
    END IF;

    -- ---- Recibiendo archivos ----------------------------------------------
    -- Acá el texto libre NO se desvía a consulta: el usuario está a mitad de un
    -- análisis y secuestrarle el turno con una respuesta de la KB haría perder
    -- los archivos que ya subió.
    IF v_sesion.estado = 'recibiendo' THEN
        IF v_tiene_doc THEN
            RETURN router_respuesta(v_chat_id, NULL, NULL, NULL,
                     jsonb_build_array(jsonb_build_object(
                       'tipo','ingerir','sesion_id', v_sesion.id)));
        END IF;

        IF v_cmd = 'svc' THEN
            RETURN router_respuesta(v_chat_id, 'sistema.servicio_ya_elegido',
                     jsonb_build_object('servicio',
                       (SELECT nombre FROM servicios WHERE codigo = v_sesion.servicio_codigo)));
        END IF;

        -- La pregunta "¿son todos?" se contesta acá (042).
        IF v_cmd = '/todos' THEN
            IF NOT EXISTS (SELECT 1 FROM documentos
                           WHERE sesion_id = v_sesion.id AND estado = 'parseado') THEN
                RETURN router_respuesta(v_chat_id, 'sistema.sin_documentos');
            END IF;
            RETURN router_respuesta(v_chat_id, 'ingesta.resumen_sesion',
                     ingesta_resumen_sesion(v_sesion.id));
        END IF;
        IF v_cmd = '/faltan' THEN
            RETURN router_respuesta(v_chat_id, 'ingesta.esperando_mas');
        END IF;

        IF v_cmd IN ('/listo','/analizar','/fin') THEN
            -- mercado_compras puede correr sin archivos en la sesión si el
            -- negocio ya tiene compras cargadas de antes (043).
            IF NOT EXISTS (SELECT 1 FROM documentos
                           WHERE sesion_id = v_sesion.id AND estado = 'parseado')
               AND NOT (v_sesion.servicio_codigo = 'mercado_compras'
                        AND EXISTS (SELECT 1 FROM mov_visibles
                                    WHERE negocio_id = v_negocio_id
                                      AND tipo = 'compra')) THEN
                RETURN router_respuesta(v_chat_id, 'sistema.sin_documentos');
            END IF;

            UPDATE sesiones SET estado = 'procesando', paso = 'ejecutando'
            WHERE id = v_sesion.id;
            INSERT INTO ejecuciones (sesion_id, negocio_id, servicio_codigo, estado)
            VALUES (v_sesion.id, v_negocio_id, v_sesion.servicio_codigo, 'preparando')
            RETURNING id INTO v_ejec_id;

            RETURN router_respuesta(v_chat_id, 'ejecucion.en_curso', '{}'::jsonb, NULL,
                     jsonb_build_array(jsonb_build_object(
                       'tipo','ejecutar','ejecucion_id', v_ejec_id)));
        END IF;

        RETURN router_respuesta(v_chat_id, 'sistema.esperando_listo');
    END IF;

    RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
END;
$$;

-- =============================================================================
-- 5. Lo que se le dice al usuario
-- =============================================================================
-- El mensaje cambia de sentido: antes anunciaba una pérdida ("dejé por fuera"),
-- ahora anuncia algo que está guardado y se activa solo. Es la verdad, y de
-- paso es el mejor argumento de venta que tiene el plan pago: los datos ya
-- están adentro, ampliar el plan no cuesta trabajo de nadie.

CREATE OR REPLACE FUNCTION ingesta_resumen_sesion(p_sesion_id bigint)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    WITH docs AS (
        SELECT d.id, d.nombre_archivo, d.filas_fuera_de_plan,
               (SELECT count(*) FROM movimientos m WHERE m.documento_id = d.id) AS filas,
               (SELECT round(coalesce(sum(m.valor_total), 0))
                  FROM movimientos m WHERE m.documento_id = d.id)               AS total
        FROM documentos d
        WHERE d.sesion_id = p_sesion_id AND d.estado = 'parseado'
    ),
    fuera AS (SELECT coalesce(sum(filas_fuera_de_plan), 0)::int AS n FROM docs)
    SELECT jsonb_build_object(
        'archivos', (SELECT count(*) FROM docs),
        'detalle',  coalesce((SELECT string_agg(
                        format('📄 %s: %s registros, $%s',
                               nombre_archivo, filas, miles(total)),
                        E'\n' ORDER BY id) FROM docs), ''),
        'total',    '$' || miles((SELECT coalesce(sum(total), 0) FROM docs)),
        'aviso_nit', CASE WHEN EXISTS (
                            SELECT 1 FROM facturas f
                            JOIN documentos d ON d.id = f.documento_id
                            WHERE d.sesion_id = p_sesion_id)
                          AND (SELECT nullif(btrim(coalesce(n.nit, '')), '')
                                 FROM negocios n
                                 JOIN sesiones s ON s.negocio_id = n.id
                                WHERE s.id = p_sesion_id) IS NULL
                     THEN E'\n\n💡 Las facturas las tomé como compras porque no tengo el NIT de tu negocio. Cargalo en tu /portal (Mi negocio) y sabré cuáles son tuyas.'
                     ELSE '' END,
        -- >>> 053: lo que el plan gratuito todavía no analiza. Se guardó todo.
        'aviso_plan', CASE WHEN (SELECT n FROM fuera) > 0
                     THEN format(E'\n\n🎁 Guardé %s registros más viejos que %s meses, pero todavía no los analizo: el plan gratuito cubre esa ventana. Están ahí esperando —si ampliás el plan entran al análisis solos, sin volver a mandarme nada—. Mirá /plan.',
                                 (SELECT n FROM fuera),
                                 coalesce((parametro(NULL, 'plan_free_meses_historia'))::text, '3'))
                     ELSE '' END
    );
$$;

-- =============================================================================
-- 6. PostgREST
-- =============================================================================
NOTIFY pgrst, 'reload schema';
