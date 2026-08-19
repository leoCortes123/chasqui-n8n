-- 054_inventario_declarado.sql — el stock deja de ser una suposición anónima.
--
-- `v_balance_unidades` (006) calcula el inventario como compradas − vendidas.
-- No hay stock inicial en ninguna parte, así que ese número es una estimación
-- desde el primer día, y sobre él se apoyan DOS de las seis reglas del informe
-- —"se agota" y "plata quieta"— más la nota de Inventario del índice de salud.
--
-- El síntoma ya estaba a la vista y se había parcheado en el texto: la 047
-- (línea 245) trata la cobertura negativa como caso propio, porque "te alcanza
-- para −95 días" no significa nada. Eso pasa cuando el negocio vendió más de lo
-- que registró comprando, que es lo normal si arrancó con mercancía en la
-- bodega — o sea, siempre.
--
-- El problema no es la fórmula: es que el resultado se presenta como si fuera
-- un hecho. Chasqui le dice a un tendero "no vuelvas a comprarlo hasta agotar
-- lo que tenés" sobre un stock que nadie contó. Si la cifra está mal, la
-- recomendación es peor que no dar ninguna.
--
-- QUÉ HACE ESTA MIGRACIÓN
--
-- 1. Una tabla de conteos: el dueño (o un archivo) declara cuántas unidades
--    hay de un producto en una fecha.
-- 2. `v_balance_unidades` pasa a distinguir TRES orígenes, y a decir cuál usó:
--
--      conteo    — hay un conteo y no hubo movimientos después. Stock contado.
--      calculado — último conteo + comprado − vendido desde esa fecha.
--      estimado  — no hay conteo: comprado − vendido. El comportamiento de
--                  siempre, que se CONSERVA, pero deja de disfrazarse de dato.
--
-- 3. Todo lo que deriva de un stock `estimado` queda marcado como tal: las dos
--    reglas lo dicen en su texto, la nota de salud lleva un asterisco con su
--    aclaración al pie, y `recomendaciones_negocio` publica `origen_stock` para
--    que cualquier consumidor futuro pueda decidir qué hacer con eso.
--
-- Lo que NO hace, a propósito: lotes, vencimientos, valuación, kardex, ajustes
-- por merma. Un modelo de inventario completo es un ERP; acá alcanza con saber
-- si el número que se le muestra al dueño lo contó alguien o lo supuso Chasqui.

-- =============================================================================
-- 1. Los conteos
-- =============================================================================
-- Un conteo es un hecho fechado, no un estado: se acumulan y siempre gana el
-- más reciente. Así un negocio puede contar la bodega cada tanto sin que haya
-- que "corregir" nada, y el histórico queda para auditar de dónde salió un
-- número viejo.
CREATE TABLE IF NOT EXISTS conteos_inventario (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    negocio_id   bigint NOT NULL REFERENCES negocios(id),
    producto_id  bigint NOT NULL REFERENCES productos(id),
    fecha        date   NOT NULL,
    unidades     numeric NOT NULL CHECK (unidades >= 0),
    origen       text   NOT NULL DEFAULT 'portal'
                        CHECK (origen IN ('portal','archivo','chat')),
    documento_id bigint REFERENCES documentos(id),
    nota         text,
    creado_en    timestamptz NOT NULL DEFAULT now(),
    -- Dos conteos del mismo producto el mismo día son una corrección, no dos
    -- hechos: el segundo pisa al primero.
    UNIQUE (negocio_id, producto_id, fecha)
);

CREATE INDEX IF NOT EXISTS idx_conteos_prod
    ON conteos_inventario (negocio_id, producto_id, fecha DESC);

COMMENT ON TABLE conteos_inventario IS
'Stock declarado por el negocio en una fecha. Sin conteos, v_balance_unidades
sigue estimando comprado − vendido y lo marca como estimado (054).';

-- =============================================================================
-- 2. v_balance_unidades: el mismo cálculo, pero diciendo de dónde sale
-- =============================================================================
-- CREATE OR REPLACE con columnas nuevas AL FINAL: `compradas` y `vendidas`
-- conservan su significado (totales del periodo visible) y solo cambia
-- `balance`. Lo único que consume esta vista es v_rotacion_producto, así que
-- el cambio de semántica está contenido.
--
-- El join contra movimientos llevaba solo `producto_id` (006:62), única de las
-- siete vistas sin `negocio_id`. No era una fuga —un producto pertenece a un
-- negocio— pero era un patrón que no había que copiar. Va corregido.
CREATE OR REPLACE VIEW v_balance_unidades AS
WITH ultimo_conteo AS (
    SELECT DISTINCT ON (negocio_id, producto_id)
           negocio_id, producto_id, fecha AS conteo_fecha, unidades AS conteo_unidades
    FROM conteos_inventario
    ORDER BY negocio_id, producto_id, fecha DESC, id DESC
)
SELECT p.negocio_id, p.id AS producto_id,
       coalesce(sum(m.cantidad) FILTER (WHERE m.tipo = 'compra'), 0) AS compradas,
       coalesce(sum(m.cantidad) FILTER (WHERE m.tipo = 'venta'),  0) AS vendidas,
       CASE WHEN c.conteo_fecha IS NULL
            THEN coalesce(sum(m.cantidad) FILTER (WHERE m.tipo = 'compra'), 0)
               - coalesce(sum(m.cantidad) FILTER (WHERE m.tipo = 'venta'),  0)
            ELSE c.conteo_unidades
               + coalesce(sum(m.cantidad) FILTER (WHERE m.tipo = 'compra'
                                                   AND m.fecha > c.conteo_fecha), 0)
               - coalesce(sum(m.cantidad) FILTER (WHERE m.tipo = 'venta'
                                                   AND m.fecha > c.conteo_fecha), 0)
       END AS balance,
       CASE WHEN c.conteo_fecha IS NULL THEN 'estimado'
            WHEN count(*) FILTER (WHERE m.fecha > c.conteo_fecha) = 0 THEN 'conteo'
            ELSE 'calculado'
       END AS origen_stock,
       c.conteo_fecha,
       c.conteo_unidades
FROM productos p
LEFT JOIN ultimo_conteo c ON c.negocio_id = p.negocio_id AND c.producto_id = p.id
LEFT JOIN mov_visibles  m ON m.producto_id = p.id AND m.negocio_id = p.negocio_id
GROUP BY p.negocio_id, p.id, c.conteo_fecha, c.conteo_unidades;

-- v_rotacion_producto solo necesita arrastrar el origen hasta las reglas.
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
       END                                                 AS dias_cobertura,
       b.origen_stock
FROM ventas v
LEFT JOIN v_balance_unidades b
       ON b.negocio_id = v.negocio_id AND b.producto_id = v.producto_id;

-- =============================================================================
-- 3. Las reglas y la salud dicen cuándo el stock es una estimación
-- =============================================================================
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
                ]) AS x WHERE x IS NOT NULL) AS opciones,
               NULL::text AS origen_stock
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
                 'Usá ese precio como referencia para negociar con los demás.') AS opciones,
               NULL::text AS origen_stock
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
                 'Si no podés subir el precio, negociá el costo o buscá otra marca equivalente.') AS opciones,
               NULL::text AS origen_stock
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
               END
               || CASE WHEN r.origen_stock = 'estimado'
                       THEN ' Ojo: es una estimación de lo comprado menos lo vendido, no un conteo tuyo.'
                       ELSE '' END AS problema,
               jsonb_build_array(
                 format('Pedí %s: es lo que vendés en los %s días que demora el proveedor más %s días de colchón.',
                        unidades_es(ceil(r.unidades_por_dia * (v_entrega + v_seguridad))),
                        fmt_decimal(v_entrega), fmt_decimal(v_seguridad)),
                 'Si el proveedor demora más de lo normal, pedí antes, no más cantidad.') AS opciones,
               r.origen_stock
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
                      fmt_decimal(r.dias_cobertura), fmt_decimal(r.unidades_por_dia))
               || CASE WHEN bal.origen_stock = 'estimado'
                       THEN ' Ojo: es una estimación de lo comprado menos lo vendido, no un conteo tuyo.'
                       ELSE '' END AS problema,
               CASE WHEN mp.margen_pct >= v_margen_alto
                    THEN jsonb_build_array(
                           format('Te deja %s%% de margen: empujalo con una promoción o ponelo a la vista, en vez de rematarlo.',
                                  fmt_decimal(mp.margen_pct)),
                           'No vuelvas a comprarlo hasta bajar lo que tenés.')
                    ELSE jsonb_build_array(
                           'No vuelvas a comprarlo hasta agotar lo que tenés.',
                           'Si sigue sin moverse, sacalo con descuento antes de que se venza o pase de moda.')
               END AS opciones,
               bal.origen_stock
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
                 'Con dos precios en la mano tenés con qué negociar; con uno solo, aceptás lo que te digan.') AS opciones,
               NULL::text AS origen_stock
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
        SELECT icono, titulo, problema, opciones, impacto_txt, origen_stock,
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
             'opciones', opciones,
             -- >>> 054: de dónde sale el stock con el que se calculó
             -- esto. 'estimado' = comprado menos vendido, sin conteo.
             'origen_stock', origen_stock)
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

    -- >>> 054: ¿la nota de inventario se calculó sobre stock estimado?
    -- Basta con que UN producto no tenga conteo: la nota es un promedio,
    -- y si parte de ella se apoya en una estimación hay que decirlo.
    SELECT bool_or(origen_stock = 'estimado') INTO v_inv_est
    FROM v_rotacion_producto
    WHERE negocio_id = p_negocio_id AND dias_cobertura IS NOT NULL;

    SELECT round(avg(n)) INTO v_indice
    FROM unnest(ARRAY[v_ventas, v_margenes, v_inventario, v_compras, v_riesgos]) AS n
    WHERE n IS NOT NULL;

    IF v_indice IS NULL THEN
        RETURN NULL;   -- sin datos suficientes, no se dibuja el semáforo
    END IF;

    RETURN jsonb_strip_nulls(jsonb_build_object(
        'ventas', v_ventas, 'margenes', v_margenes, 'inventario', v_inventario,
        'compras', v_compras, 'riesgos', v_riesgos, 'indice', v_indice,
        'inventario_estimado', CASE WHEN v_inventario IS NULL THEN NULL
                                    ELSE coalesce(v_inv_est, false) END));
END;
$$;
CREATE OR REPLACE FUNCTION informe_salud_bloque(p_salud jsonb, p_servicio text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_lineas text[] := '{}';
    v_tmp    text;
    v_clave  text;
    v_eti    text;
    v_val    numeric;
BEGIN
    IF p_salud IS NULL OR jsonb_typeof(p_salud) <> 'object'
       OR p_salud -> 'indice' IS NULL THEN
        RETURN NULL;
    END IF;

    v_tmp := plantilla_cuerpo_srv('informe.salud_linea', p_servicio,
               '{{semaforo}} {{etiqueta}} <code>{{barra}}</code> {{valor}}');

    FOR v_clave, v_eti IN
        SELECT * FROM (VALUES ('ventas','Ventas    '), ('margenes','Márgenes  '),
                              ('inventario','Inventario'), ('compras','Compras   '),
                              ('riesgos','Riesgos   ')) AS t(c, e)
    LOOP
        CONTINUE WHEN p_salud -> v_clave IS NULL;
        v_val := (p_salud ->> v_clave)::numeric;
        -- >>> 054: la nota de inventario calculada sobre stock sin conteo
        -- lleva una marca. No se oculta la nota —sería peor— pero tampoco
        -- se presenta como si el stock fuera un dato conocido.
        v_lineas := v_lineas || replace(replace(replace(replace(v_tmp,
            '{{semaforo}}', semaforo(v_val)),
            '{{etiqueta}}', esc_html(v_eti)),
            '{{barra}}',    barra_10(v_val)),
            '{{valor}}',    lpad(v_val::int::text, 3, ' ')
              || CASE WHEN v_clave = 'inventario'
                       AND (p_salud ->> 'inventario_estimado')::boolean
                      THEN ' *' ELSE '' END);
    END LOOP;

    IF cardinality(v_lineas) = 0 THEN
        RETURN NULL;
    END IF;

    -- La nota al pie solo aparece si hubo algo que marcar.
    IF coalesce((p_salud ->> 'inventario_estimado')::boolean, false)
       AND p_salud -> 'inventario' IS NOT NULL THEN
        -- array_append y no `||`: con un literal sin tipo, `text[] || '...'`
        -- resuelve a array_cat e intenta leer la frase como un array.
        v_lineas := array_append(v_lineas,
            E'\n<i>* Inventario estimado: es lo que compraste menos lo que vendiste. Pasame un conteo y la nota se calcula sobre tu stock real.</i>');
    END IF;

    RETURN replace(replace(
        plantilla_cuerpo_srv('informe.salud', p_servicio,
            E'🩺 <b>Salud del negocio</b>\n{{lineas}}\n\n<b>Índice general: {{indice}}/100</b>'),
        '{{lineas}}', array_to_string(v_lineas, E'\n')),
        '{{indice}}', (p_salud ->> 'indice'));
END;
$$;

-- =============================================================================
-- 4. Cómo entra un conteo
-- =============================================================================
-- Dos vías, ninguna nueva en infraestructura:
--
--   * El portal, con dos RPC más bajo las mismas reglas de la 033 (el
--     negocio_id sale del JWT, nunca del parámetro).
--   * Un archivo tabular, clase 'tabular', que reusa la cadena completa de la
--     017 —extracción en n8n, huella de cabeceras, compuerta de calidad— sin
--     tocar un solo nodo. La diferencia es la función de carga.
--
-- El mapeo va fijo, no inferido: un archivo de conteo tiene tres columnas y no
-- justifica gastar tokens. Cuando aparezca el primer formato ajeno se le agrega
-- la huella, igual que con las ventas.

-- Carga desde archivo. Espeja a ingesta_cargar_tabular (019) pero escribe en
-- conteos_inventario: resuelve el producto por el mismo matcher que todo lo
-- demás, así "Arroz Diana x500" del conteo cae en el mismo producto que la
-- factura. Lo que no se puede emparejar NO se inventa: se cuenta y se reporta.
CREATE OR REPLACE FUNCTION ingesta_cargar_inventario(p_documento_id bigint, p_filas jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_negocio_id bigint;
    v_mapeo      jsonb;
    v_cols       jsonb;
    v_dec        text;
    v_mil        text;
    v_fmt        text;
    v_estado     estado_doc;
    v_error      text;
    v_n          int := 0;
    v_sin_prod   int := 0;
BEGIN
    SELECT d.estado, d.error, d.negocio_id, f.mapeo
      INTO v_estado, v_error, v_negocio_id, v_mapeo
    FROM documentos d
    LEFT JOIN formatos_documento f ON f.codigo = d.formato_codigo
    WHERE d.id = p_documento_id;

    IF v_estado = 'error' THEN
        RETURN jsonb_build_object('documento_id', p_documento_id,
                                  'estado', 'error', 'error', v_error);
    END IF;
    IF v_mapeo IS NULL THEN
        RETURN ingesta_marcar_error(p_documento_id, 'el documento no tiene formato asignado');
    END IF;

    v_cols := v_mapeo -> 'columnas';
    v_dec  := coalesce(v_mapeo ->> 'decimal', '.');
    v_mil  := coalesce(v_mapeo ->> 'miles', '');
    v_fmt  := v_mapeo ->> 'formato_fecha';

    WITH filas AS (
        SELECT ingesta_fecha(r -> (v_cols ->> 'fecha'), v_fmt)                 AS fecha,
               btrim(coalesce(r ->> (v_cols ->> 'producto'), ''))              AS producto_txt,
               ingesta_num  (r -> (v_cols ->> 'unidades'), v_dec, v_mil)       AS unidades
        FROM jsonb_array_elements(coalesce(p_filas, '[]'::jsonb)) AS r
    ),
    resueltas AS (
        -- Un conteo sin fecha legible es un conteo de hoy: es lo que acaba de
        -- hacer quien mandó el archivo. Pero `to_date` es indulgente y con un
        -- patrón mal declarado devuelve basura en vez de fallar (14/08/2026 con
        -- 'YYYY-MM-DD' da 2008-01-01), así que lo absurdo se descarta antes de
        -- caer al default en vez de guardarse como si fuera un dato.
        SELECT coalesce(CASE WHEN fecha BETWEEN date '2000-01-01' AND current_date + 1
                             THEN fecha END, current_date) AS fecha,
               producto_txt, unidades,
               (match_resolver_producto(v_negocio_id, producto_txt) ->> 'producto_id')::bigint AS producto_id
        FROM filas
        WHERE nullif(producto_txt, '') IS NOT NULL AND unidades IS NOT NULL
    ),
    ins AS (
        INSERT INTO conteos_inventario
               (negocio_id, producto_id, fecha, unidades, origen, documento_id)
        SELECT v_negocio_id, producto_id, fecha, unidades, 'archivo', p_documento_id
        FROM resueltas WHERE producto_id IS NOT NULL
        ON CONFLICT (negocio_id, producto_id, fecha)
          DO UPDATE SET unidades = EXCLUDED.unidades,
                        origen   = EXCLUDED.origen,
                        documento_id = EXCLUDED.documento_id
        RETURNING 1
    )
    SELECT (SELECT count(*) FROM ins),
           (SELECT count(*) FROM resueltas WHERE producto_id IS NULL)
      INTO v_n, v_sin_prod;

    UPDATE documentos SET estado = 'parseado', error = NULL WHERE id = p_documento_id;

    RETURN jsonb_build_object('documento_id', p_documento_id, 'estado', 'parseado',
                              'clase', 'inventario', 'conteos', v_n,
                              'sin_producto', v_sin_prod);
END;
$$;

-- El formato. `huella` queda NULL: se identifica por extensión y por ser el
-- único de clase 'tabular' con funcion_parseo de inventario cuando el usuario
-- lo elige. La inferencia por LLM para conteos se deja para cuando exista un
-- segundo formato real.
INSERT INTO formatos_documento (codigo, nombre, mime_patrones, extensiones, funcion_parseo,
                                clase, mapeo, origen, activo)
VALUES ('inventario_csv', 'Conteo de inventario',
        ARRAY['text/csv','application/vnd.ms-excel'],
        ARRAY['csv','tsv','txt','xls','xlsx','ods'],
        'ingesta_cargar_inventario', 'tabular',
        jsonb_build_object(
          'columnas', jsonb_build_object('producto','producto','unidades','unidades','fecha','fecha'),
          'decimal', ',', 'miles', '.', 'formato_fecha', 'DD/MM/YYYY'),
        'semilla', true)
ON CONFLICT (codigo) DO UPDATE
  SET funcion_parseo = EXCLUDED.funcion_parseo,
      clase          = EXCLUDED.clase,
      mapeo          = EXCLUDED.mapeo,
      activo         = true;

-- --- Portal ------------------------------------------------------------------
CREATE OR REPLACE FUNCTION portal_conteos(p_limite int DEFAULT 50)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'id', c.id, 'producto', p.nombre_canonico, 'producto_id', p.id,
             'fecha', c.fecha, 'unidades', c.unidades, 'origen', c.origen)
             ORDER BY c.fecha DESC, c.id DESC), '[]'::jsonb)
    FROM (SELECT * FROM conteos_inventario
          WHERE negocio_id = portal_negocio()
          ORDER BY fecha DESC, id DESC
          LIMIT greatest(coalesce(p_limite, 50), 1)) c
    JOIN productos p ON p.id = c.producto_id;
$$;

CREATE OR REPLACE FUNCTION portal_conteo_guardar(p_producto_id bigint,
                                                 p_unidades numeric,
                                                 p_fecha date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_negocio bigint := portal_negocio();
    v_id      bigint;
BEGIN
    -- El producto tiene que ser de este negocio: el id llega del navegador.
    IF NOT EXISTS (SELECT 1 FROM productos
                   WHERE id = p_producto_id AND negocio_id = v_negocio) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'producto_ajeno');
    END IF;
    IF p_unidades IS NULL OR p_unidades < 0 THEN
        RETURN jsonb_build_object('ok', false, 'error', 'unidades_invalidas');
    END IF;

    INSERT INTO conteos_inventario (negocio_id, producto_id, fecha, unidades, origen)
    VALUES (v_negocio, p_producto_id, coalesce(p_fecha, current_date), p_unidades, 'portal')
    ON CONFLICT (negocio_id, producto_id, fecha)
      DO UPDATE SET unidades = EXCLUDED.unidades, origen = 'portal'
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'id', v_id);
END;
$$;

-- Los productos, para poder elegir a cuál se le carga el conteo.
CREATE OR REPLACE FUNCTION portal_productos()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'id', p.id, 'nombre', p.nombre_canonico, 'unidad', p.unidad,
             'stock', b.balance, 'origen_stock', b.origen_stock,
             'conteo_fecha', b.conteo_fecha)
             ORDER BY p.nombre_canonico), '[]'::jsonb)
    FROM productos p
    LEFT JOIN v_balance_unidades b
           ON b.negocio_id = p.negocio_id AND b.producto_id = p.id
    WHERE p.negocio_id = portal_negocio();
$$;

GRANT EXECUTE ON FUNCTION portal_conteos(int)                            TO portal_usuario;
GRANT EXECUTE ON FUNCTION portal_conteo_guardar(bigint, numeric, date)   TO portal_usuario;
GRANT EXECUTE ON FUNCTION portal_productos()                             TO portal_usuario;

NOTIFY pgrst, 'reload schema';
