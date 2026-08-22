-- 047_informe_prescriptivo.sql — el informe deja de describir y pasa a recetar.
--
-- Hasta acá el informe decía "el costo de la panela subió 10,53%". Eso es un
-- dato. Lo que sirve es una decisión:
--
--   La panela cuadrada 500 g te subió 10,53%.
--   Tu margen baja de 31,2% a 27,8%. Son unos $84.000 más al mes.
--   ✓ Negociá con el proveedor.
--   ✓ Comprale a Distribuidora Sur, que te la dejó a $2.900.
--   ✓ Si no conseguís mejor precio, subí el precio de venta a $4.150.
--   Prioridad: alta.
--
-- DÓNDE SE CALCULA ESO, Y POR QUÉ NO LO HACE EL MODELO
-- ----------------------------------------------------
-- El impacto en pesos, el margen resultante, el precio sugerido, la cantidad a
-- comprar y el proveedor más barato los calcula SQL. El modelo solo los redacta.
-- No es purismo: `validar_cifras` rechaza el informe si aparece un número que no
-- esté en los hallazgos, así que un impacto "estimado" por el modelo tumbaría la
-- entrega y caería al informe seco. Además las recomendaciones son REGLAS, y una
-- regla es una fila y una consulta, no una frase suelta que el modelo improvisa
-- distinto en cada corrida.
--
-- Todo lo de acá es Nivel 1: sale del historial del propio negocio, sin datos
-- externos. Los niveles 2 (precios oficiales tipo SIPSA) y 3 (benchmark entre
-- negocios anonimizados) están descritos en docs/PLAN_PRODUCCION.md; el contrato
-- de `recomendaciones_negocio` es el mismo, cambia de dónde sale el comparativo.
--
-- Contenido:
--   1. Umbrales nuevos (parámetros por negocio)
--   2. recomendaciones_negocio: el motor de reglas
--   3. salud_negocio: el semáforo de arriba del informe
--   4. hallazgos_generar / hallazgos_compras: los publican
--   5. Plantillas de layout y informe_render
--   6. El informe seco = la salida cruda del motor
--   7. Prompts

-- =============================================================================
-- 1. Umbrales
-- =============================================================================
INSERT INTO parametros (negocio_id, clave, valor) VALUES
  -- Cuánto demora el proveedor en entregar y cuántos días de colchón se quieren.
  -- Los dos entran en la cantidad sugerida de compra.
  (NULL, 'dias_entrega_proveedor',    '4'::jsonb),
  (NULL, 'dias_stock_seguridad',      '3'::jsonb),
  -- Por encima de esta cobertura el producto es plata quieta, no inventario.
  (NULL, 'rotacion_lenta_dias',       '60'::jsonb),
  -- Margen a partir del cual conviene empujar la venta en vez de recortar.
  (NULL, 'margen_alto_pct',           '35'::jsonb),
  -- Concentración de compras en un solo proveedor que ya es riesgo.
  (NULL, 'dependencia_proveedor_pct', '50'::jsonb),
  -- Prioridad de una recomendación: su impacto mensual medido contra lo que
  -- mueve el negocio en un mes. Relativo a propósito: $80.000 es enorme para
  -- una tienda y ruido para una distribuidora.
  (NULL, 'prioridad_alta_pct',        '2'::jsonb),
  (NULL, 'prioridad_media_pct',       '0.5'::jsonb)
ON CONFLICT (clave) WHERE negocio_id IS NULL
DO UPDATE SET valor = EXCLUDED.valor;

-- =============================================================================
-- 2. El motor de reglas
-- =============================================================================
-- Devuelve una lista de PROBLEMAS, y cada uno contesta las cuatro preguntas que
-- un dueño se hace: qué pasa, por qué es un problema, cuánto cuesta y qué hacer.
--
-- Forma de cada elemento:
--   {icono, prioridad, titulo, problema, impacto, impacto_mes, opciones[]}
--
-- `impacto_mes` va crudo (número) además del texto: es lo que ordena la lista y
-- lo que le da a validar_cifras la cifra exacta que el modelo va a copiar.
--
-- Cada regla aporta como mucho DOS problemas (el `rn <= 2` del final). Sin ese
-- tope, un negocio con veinte productos por agotarse llena el informe entero con
-- la misma regla y el dueño no se entera de que además está perdiendo margen: la
-- variedad de ángulos vale más que el ranking puro de pesos. Pasó con los datos
-- de prueba y por eso está.

-- "1 unidad" / "21 unidades". Trivial, pero un "Pedí 1 unidades" en el primer
-- informe que ve un cliente le quita seriedad a todo lo demás.
CREATE OR REPLACE FUNCTION unidades_es(p_n numeric) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN round(coalesce(p_n, 0)) = 1 THEN '1 unidad'
                ELSE round(coalesce(p_n, 0))::int::text || ' unidades' END;
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
    FROM movimientos WHERE negocio_id = p_negocio_id AND fecha IS NOT NULL;
    v_meses := coalesce(v_meses, 1);

    SELECT greatest(coalesce(sum(valor_total) FILTER (WHERE tipo = 'venta'),
                             sum(valor_total) FILTER (WHERE tipo = 'compra'), 0) / v_meses, 1)
      INTO v_base_mes
    FROM movimientos WHERE negocio_id = p_negocio_id;

    WITH
    -- Unidades compradas y vendidas por producto.
    base AS (
        SELECT m.producto_id,
               sum(m.cantidad) FILTER (WHERE m.tipo = 'compra') AS u_compradas,
               sum(m.cantidad) FILTER (WHERE m.tipo = 'venta')  AS u_vendidas
        FROM movimientos m
        WHERE m.negocio_id = p_negocio_id AND m.producto_id IS NOT NULL
        GROUP BY 1
    ),
    -- Precio promedio por proveedor, para saber si hay dónde comprar más barato.
    por_proveedor AS (
        SELECT m.producto_id,
               nullif(btrim(coalesce(m.raw ->> 'proveedor', '')), '') AS proveedor,
               sum(m.cantidad)                                        AS u,
               sum(m.valor_total) / nullif(sum(m.cantidad), 0)        AS precio_prom
        FROM movimientos m
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
        FROM movimientos m
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

-- =============================================================================
-- 3. Salud del negocio
-- =============================================================================
-- Cinco notas de 0 a 100 y un índice. Va arriba del informe porque un dueño
-- entiende antes una valoración global que una lista de métricas — y porque le
-- da al informe un ancla que se puede comparar con la corrida del mes pasado.
--
-- Cada nota se calcula sobre lo que HAY: si el negocio no cargó ventas, la nota
-- de ventas es NULL y no entra al promedio. Inventar un 0 sería mentir.
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
    FROM movimientos WHERE negocio_id = p_negocio_id AND fecha IS NOT NULL;

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
        FROM movimientos
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
          FROM movimientos
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

-- =============================================================================
-- 4. Los hallazgos publican salud y recomendaciones
-- =============================================================================
-- hallazgos_generar v4: lo de la 025 más `salud`, `recomendaciones` y el tipo de
-- negocio (046). Las listas viejas se quedan: son las que dan las cifras sueltas
-- que el modelo puede citar y las que usa el encabezado.
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
                  FROM movimientos
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

-- mercado_compras: mismas dos claves nuevas sobre la función de la 043. Las
-- reglas que necesitan ventas no devuelven nada cuando no hay ventas, así que
-- la lista sale sola con lo que aplica (costo al alza, proveedor más barato,
-- dependencia).
CREATE OR REPLACE FUNCTION hallazgos_compras(p_negocio_id bigint, p_contexto jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT hallazgos_compras(p_negocio_id)
           || jsonb_build_object(
                'salud', salud_negocio(p_negocio_id),
                'recomendaciones', recomendaciones_negocio(p_negocio_id),
                'tipo_negocio', (SELECT coalesce(t.nombre, n.tipo)
                                 FROM negocios n
                                 LEFT JOIN tipos_negocio t ON t.codigo = n.tipo
                                 WHERE n.id = p_negocio_id));
$$;

-- =============================================================================
-- 5. Layout
-- =============================================================================
INSERT INTO plantillas (clave, cuerpo, formato, variables, crudas, teclado) VALUES

('informe.salud',
 '🩺 <b>Salud del negocio</b>
{{lineas}}

<b>Índice general: {{indice}}/100</b>',
 'html', '["lineas","indice"]'::jsonb, '["lineas"]'::jsonb, '[]'::jsonb),

('informe.salud_linea',
 '{{semaforo}} {{etiqueta}} <code>{{barra}}</code> {{valor}}',
 'html', '["semaforo","etiqueta","barra","valor"]'::jsonb, '[]'::jsonb, '[]'::jsonb),

-- Un problema = un bloque. Se compone de piezas para que un bloque sin impacto
-- calculable (la dependencia de proveedor) no deje una línea vacía.
('informe.hallazgo_titulo', '{{icono}} <b>{{titulo}}</b>',
 'html', '["icono","titulo"]'::jsonb, '[]'::jsonb, '[]'::jsonb),

('informe.hallazgo_problema', '{{texto}}',
 'html', '["texto"]'::jsonb, '[]'::jsonb, '[]'::jsonb),

('informe.hallazgo_impacto', '💸 <b>{{texto}}</b>',
 'html', '["texto"]'::jsonb, '[]'::jsonb, '[]'::jsonb),

('informe.opcion', '✓ {{texto}}',
 'html', '["texto"]'::jsonb, '[]'::jsonb, '[]'::jsonb),

('informe.hallazgo_prioridad', '{{semaforo}} Prioridad {{nivel}}',
 'html', '["semaforo","nivel"]'::jsonb, '[]'::jsonb, '[]'::jsonb)

ON CONFLICT (clave) DO UPDATE
  SET cuerpo = EXCLUDED.cuerpo, formato = EXCLUDED.formato,
      variables = EXCLUDED.variables, crudas = EXCLUDED.crudas,
      activo = true, version = plantillas.version + 1;

UPDATE plantillas SET cuerpo =
'<i>Las cifras y los cálculos salen de los archivos que me mandaste. Si alguna no te cuadra, decime y la reviso.</i>',
  version = version + 1
WHERE clave = 'informe.pie';

-- Semáforo compartido por el índice de salud y la prioridad de cada problema.
CREATE OR REPLACE FUNCTION semaforo(p_valor numeric) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_valor IS NULL THEN '⚪'
                WHEN p_valor >= 80 THEN '🟢'
                WHEN p_valor >= 65 THEN '🟡'
                WHEN p_valor >= 50 THEN '🟠'
                ELSE '🔴' END;
$$;

-- Barra de 10 bloques. Monoespaciada en el render (<code>) para que las cinco
-- líneas queden alineadas en el chat.
CREATE OR REPLACE FUNCTION barra_10(p_valor numeric) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT repeat('█', greatest(0, least(10, round(coalesce(p_valor,0)/10)::int)))
        || repeat('░', 10 - greatest(0, least(10, round(coalesce(p_valor,0)/10)::int)));
$$;

-- El bloque de salud se arma entero en SQL: son cifras de la base y no pasan
-- por el modelo en ningún momento.
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
        v_lineas := v_lineas || replace(replace(replace(replace(v_tmp,
            '{{semaforo}}', semaforo(v_val)),
            '{{etiqueta}}', esc_html(v_eti)),
            '{{barra}}',    barra_10(v_val)),
            '{{valor}}',    lpad(v_val::int::text, 3, ' '));
    END LOOP;

    IF cardinality(v_lineas) = 0 THEN
        RETURN NULL;
    END IF;

    RETURN replace(replace(
        plantilla_cuerpo_srv('informe.salud', p_servicio,
            E'🩺 <b>Salud del negocio</b>\n{{lineas}}\n\n<b>Índice general: {{indice}}/100</b>'),
        '{{lineas}}', array_to_string(v_lineas, E'\n')),
        '{{indice}}', (p_salud ->> 'indice'));
END;
$$;

-- === informe_render v4 ======================================================
-- Cambia en dos puntos respecto de la 030:
--   * después del encabezado dibuja la salud del negocio, si la hay;
--   * acepta `hallazgos[]` (bloques con problema, impacto, opciones y
--     prioridad) además de las `secciones[]` de siempre. Las dos formas
--     conviven: un servicio que no tenga motor de reglas sigue con secciones.
CREATE OR REPLACE FUNCTION informe_render(p_estructura jsonb, p_hallazgos jsonb,
                                          p_servicio text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_iconos_ok text[] := ARRAY['⚠️','📈','📉','📦','💰','🏆','🔎','🧾','🕐','✅'];
    v_bloques   text[] := '{}';
    v_metricas  text[] := '{}';
    v_partes    text[];
    v_puntos    text[];
    v_enc       jsonb;
    v_sec       jsonb;
    v_pt        text;
    v_icono     text;
    v_titular   text;
    v_nombre    text;
    v_subtitulo text;
    v_margen    text;
    v_prio      text;
    v_prod      int;
    v_n         int;
    v_tmp       text;
BEGIN
    IF p_estructura IS NULL OR jsonb_typeof(p_estructura) <> 'object' THEN
        RETURN NULL;
    END IF;
    v_titular := limpiar_marcado(p_estructura ->> 'titular');
    IF coalesce(v_titular, '') = '' THEN
        RETURN NULL;
    END IF;

    v_enc := CASE WHEN jsonb_typeof(p_hallazgos -> 'encabezado') = 'object'
                  THEN p_hallazgos -> 'encabezado' ELSE NULL END;
    v_tmp := plantilla_cuerpo_srv('informe.metrica', p_servicio,
                                  '{{icono}} {{etiqueta}}: <b>{{valor}}</b>');

    IF v_enc IS NOT NULL THEN
        -- --- Cabecera declarada por el servicio ------------------------------
        v_nombre    := coalesce(nullif(v_enc ->> 'titulo', ''),
                        (SELECT nombre FROM servicios WHERE codigo = p_servicio),
                        'Tu negocio');
        v_subtitulo := coalesce(v_enc ->> 'subtitulo', '');

        IF jsonb_typeof(v_enc -> 'metricas') = 'array' THEN
            FOR v_sec IN SELECT * FROM jsonb_array_elements(v_enc -> 'metricas') LOOP
                CONTINUE WHEN jsonb_typeof(v_sec) <> 'object';
                CONTINUE WHEN coalesce(v_sec ->> 'etiqueta', '') = '';
                v_icono := v_sec ->> 'icono';
                IF v_icono IS NULL OR NOT (v_icono = ANY(v_iconos_ok)) THEN
                    v_icono := '🔎';
                END IF;
                v_metricas := v_metricas || replace(replace(replace(v_tmp,
                    '{{icono}}', v_icono),
                    '{{etiqueta}}', esc_html(v_sec ->> 'etiqueta')),
                    '{{valor}}', esc_html(coalesce(v_sec ->> 'valor', '')));
            END LOOP;
        END IF;
    ELSE
        -- --- Cabecera de ventas-compras: cifras de la base, no del modelo ----
        v_nombre := coalesce((SELECT nombre FROM servicios WHERE codigo = p_servicio),
                             'Análisis de tu negocio');
        v_prod   := coalesce((p_hallazgos #>> '{resumen,productos}')::int, 0);
        v_margen := fmt_decimal((p_hallazgos #>> '{resumen,margen_promedio_pct}')::numeric);

        IF v_prod > 0 THEN
            v_metricas := v_metricas || replace(replace(replace(v_tmp,
                '{{icono}}', '📦'), '{{etiqueta}}', 'Productos analizados'),
                '{{valor}}', v_prod::text);
        END IF;
        IF v_margen <> '' THEN
            v_metricas := v_metricas || replace(replace(replace(v_tmp,
                '{{icono}}', '💰'), '{{etiqueta}}', 'Margen promedio'),
                '{{valor}}', v_margen || ' %');
        END IF;

        FOR v_icono, v_pt, v_n IN
            SELECT * FROM (VALUES
                ('⚠️', 'Con margen bajo',   jsonb_array_length(coalesce(p_hallazgos->'margen_bajo','[]'::jsonb))),
                ('📈', 'Con costo al alza', jsonb_array_length(coalesce(p_hallazgos->'deriva_costo','[]'::jsonb))),
                ('🕐', 'Se agotan pronto',  jsonb_array_length(coalesce(p_hallazgos->'baja_cobertura','[]'::jsonb))),
                ('🏆', 'Concentran la ganancia', jsonb_array_length(coalesce(p_hallazgos->'pareto','[]'::jsonb)))
            ) AS t(ico, eti, n) WHERE t.n > 0
        LOOP
            v_metricas := v_metricas || replace(replace(replace(v_tmp,
                '{{icono}}', v_icono), '{{etiqueta}}', v_pt), '{{valor}}', v_n::text);
        END LOOP;

        v_subtitulo := coalesce(nullif(
            periodo_es((p_hallazgos #>> '{periodo,desde}')::date,
                       (p_hallazgos #>> '{periodo,hasta}')::date), ''),
            'con los archivos que me mandaste');
    END IF;

    v_bloques := v_bloques || replace(replace(replace(
        plantilla_cuerpo_srv('informe.encabezado', p_servicio,
            E'📊 <b>{{servicio}}</b>\n<i>{{periodo}}</i>\n\n{{metricas}}'),
        '{{servicio}}', esc_html(v_nombre)),
        '{{periodo}}',  esc_html(v_subtitulo)),
        '{{metricas}}', array_to_string(v_metricas, E'\n'));

    -- --- Salud del negocio (de la base, no del modelo) ----------------------
    v_tmp := informe_salud_bloque(p_hallazgos -> 'salud', p_servicio);
    IF v_tmp IS NOT NULL THEN
        v_bloques := v_bloques || v_tmp;
    END IF;

    -- --- Titular ------------------------------------------------------------
    v_bloques := v_bloques || replace(
        plantilla_cuerpo_srv('informe.titular', p_servicio, '<b>{{titular}}</b>'),
        '{{titular}}', esc_html(v_titular));

    -- --- Hallazgos prescriptivos --------------------------------------------
    IF jsonb_typeof(p_estructura -> 'hallazgos') = 'array' THEN
        FOR v_sec IN SELECT * FROM jsonb_array_elements(p_estructura -> 'hallazgos') LOOP
            CONTINUE WHEN jsonb_typeof(v_sec) <> 'object';
            CONTINUE WHEN coalesce(v_sec ->> 'titulo', '') = '';

            v_icono := v_sec ->> 'icono';
            IF v_icono IS NULL OR NOT (v_icono = ANY(v_iconos_ok)) THEN
                v_icono := '🔎';
            END IF;

            v_partes := ARRAY[ replace(replace(
                plantilla_cuerpo_srv('informe.hallazgo_titulo', p_servicio,
                    '{{icono}} <b>{{titulo}}</b>'),
                '{{icono}}',  v_icono),
                '{{titulo}}', esc_html(limpiar_marcado(v_sec ->> 'titulo'))) ];

            IF coalesce(btrim(v_sec ->> 'problema'), '') <> '' THEN
                v_partes := v_partes || replace(
                    plantilla_cuerpo_srv('informe.hallazgo_problema', p_servicio, '{{texto}}'),
                    '{{texto}}', esc_html(limpiar_marcado(v_sec ->> 'problema')));
            END IF;

            IF coalesce(btrim(v_sec ->> 'impacto'), '') <> '' THEN
                v_partes := v_partes || replace(
                    plantilla_cuerpo_srv('informe.hallazgo_impacto', p_servicio,
                        '💸 <b>{{texto}}</b>'),
                    '{{texto}}', esc_html(limpiar_marcado(v_sec ->> 'impacto')));
            END IF;

            IF jsonb_typeof(v_sec -> 'opciones') = 'array' THEN
                FOR v_pt IN SELECT * FROM jsonb_array_elements_text(v_sec -> 'opciones') LOOP
                    CONTINUE WHEN coalesce(btrim(v_pt), '') = '';
                    v_partes := v_partes || replace(
                        plantilla_cuerpo_srv('informe.opcion', p_servicio, '✓ {{texto}}'),
                        '{{texto}}', esc_html(limpiar_marcado(v_pt)));
                END LOOP;
            END IF;

            -- La prioridad del modelo solo se acepta si es una de las tres.
            v_prio := lower(coalesce(v_sec ->> 'prioridad', ''));
            IF v_prio IN ('alta','media','baja') THEN
                v_partes := v_partes || replace(replace(
                    plantilla_cuerpo_srv('informe.hallazgo_prioridad', p_servicio,
                        '{{semaforo}} Prioridad {{nivel}}'),
                    '{{semaforo}}', CASE v_prio WHEN 'alta' THEN '🔴'
                                                WHEN 'media' THEN '🟡' ELSE '🟢' END),
                    '{{nivel}}', v_prio);
            END IF;

            v_bloques := v_bloques || array_to_string(v_partes, E'\n');
        END LOOP;
    END IF;

    -- --- Secciones (forma clásica; la usan los servicios sin motor de reglas) -
    IF jsonb_typeof(p_estructura -> 'secciones') = 'array' THEN
        FOR v_sec IN SELECT * FROM jsonb_array_elements(p_estructura -> 'secciones') LOOP
            CONTINUE WHEN jsonb_typeof(v_sec) <> 'object';
            CONTINUE WHEN coalesce(v_sec ->> 'titulo', '') = '';

            v_puntos := '{}';
            IF jsonb_typeof(v_sec -> 'puntos') = 'array' THEN
                FOR v_pt IN SELECT * FROM jsonb_array_elements_text(v_sec -> 'puntos') LOOP
                    CONTINUE WHEN coalesce(btrim(v_pt), '') = '';
                    v_puntos := v_puntos || replace(
                        plantilla_cuerpo_srv('informe.punto', p_servicio, '• {{texto}}'),
                        '{{texto}}', esc_html(limpiar_marcado(v_pt)));
                END LOOP;
            END IF;
            CONTINUE WHEN cardinality(v_puntos) = 0;

            v_icono := v_sec ->> 'icono';
            IF v_icono IS NULL OR NOT (v_icono = ANY(v_iconos_ok)) THEN
                v_icono := '🔎';
            END IF;

            v_bloques := v_bloques || replace(replace(replace(
                plantilla_cuerpo_srv('informe.seccion', p_servicio,
                    E'{{icono}} <b>{{titulo}}</b>\n{{puntos}}'),
                '{{icono}}',  v_icono),
                '{{titulo}}', esc_html(limpiar_marcado(v_sec ->> 'titulo'))),
                '{{puntos}}', array_to_string(v_puntos, E'\n'));
        END LOOP;
    END IF;

    -- --- Acciones -----------------------------------------------------------
    IF jsonb_typeof(p_estructura -> 'acciones') = 'array' THEN
        v_puntos := '{}';
        v_n := 0;
        FOR v_pt IN SELECT * FROM jsonb_array_elements_text(p_estructura -> 'acciones') LOOP
            CONTINUE WHEN coalesce(btrim(v_pt), '') = '';
            v_n := v_n + 1;
            v_puntos := v_puntos || replace(replace(
                plantilla_cuerpo_srv('informe.accion', p_servicio, '{{n}}. {{texto}}'),
                '{{n}}', v_n::text),
                '{{texto}}', esc_html(limpiar_marcado(v_pt)));
        END LOOP;
        IF cardinality(v_puntos) > 0 THEN
            v_bloques := v_bloques || replace(
                plantilla_cuerpo_srv('informe.acciones', p_servicio,
                    E'✅ <b>Qué hacer esta semana</b>\n{{puntos}}'),
                '{{puntos}}', array_to_string(v_puntos, E'\n'));
        END IF;
    END IF;

    -- --- Pie ----------------------------------------------------------------
    IF coalesce((p_estructura ->> 'narrado')::boolean, true) = false THEN
        v_bloques := v_bloques || plantilla_cuerpo_srv('informe.sin_narracion', p_servicio, '');
    END IF;
    v_bloques := v_bloques || plantilla_cuerpo_srv('informe.pie', p_servicio, '');

    RETURN array_to_string(array_remove(v_bloques, ''), E'\n\n');
END;
$$;

-- =============================================================================
-- 6. El informe seco = el motor de reglas sin narrar
-- =============================================================================
-- Antes el camino de reserva era una lista de datos pelados. Ahora, cuando hay
-- recomendaciones, el seco es exactamente lo que calculó SQL: pierde la
-- redacción, no el contenido. Es la mejor prueba de que el valor no lo pone el
-- modelo.
CREATE OR REPLACE FUNCTION informe_estructura_seca(p_hallazgos jsonb,
                                                   p_servicio  text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_h    jsonb := coalesce(p_hallazgos, '{}'::jsonb);
    v_sec  jsonb := '[]'::jsonb;
    v_hall jsonb := '[]'::jsonb;
    v_pts  jsonb;
BEGIN
    IF jsonb_typeof(v_h -> 'recomendaciones') = 'array'
       AND jsonb_array_length(v_h -> 'recomendaciones') > 0 THEN
        SELECT jsonb_agg(jsonb_build_object(
                 'icono', e ->> 'icono', 'titulo', e ->> 'titulo',
                 'problema', e ->> 'problema', 'impacto', e ->> 'impacto',
                 'opciones', coalesce(e -> 'opciones', '[]'::jsonb),
                 'prioridad', e ->> 'prioridad'))
          INTO v_hall
        FROM (SELECT e FROM jsonb_array_elements(v_h -> 'recomendaciones') e LIMIT 5) s;

        RETURN jsonb_build_object(
            'titular', plantilla_cuerpo_srv('informe.titular_seco', p_servicio,
                         'Esto es lo que encontré en tus números'),
            'hallazgos', coalesce(v_hall, '[]'::jsonb),
            'secciones', '[]'::jsonb,
            'acciones',  '[]'::jsonb,
            'narrado',   false);
    END IF;

    -- Las cifras se copian tal cual del JSON de hallazgos, sin reformatear: son
    -- exactamente las que validar_cifras daría por buenas.
    IF jsonb_typeof(v_h -> 'hechos') = 'array'
       AND jsonb_array_length(v_h -> 'hechos') > 0 THEN
        SELECT jsonb_agg(btrim(coalesce(nullif(e ->> 'contenido', ''), e ->> 'titulo')))
          INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(v_h -> 'hechos') e LIMIT 3) s;

        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '🔎', 'titulo', 'Lo que tengo cargado', 'puntos', v_pts));
        END IF;
    ELSE
        SELECT jsonb_agg(format('%s: deja %s%% de margen',
                                e ->> 'producto', e ->> 'margen_pct')) INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(coalesce(v_h->'margen_bajo','[]'::jsonb)) e
              LIMIT 3) s;
        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '⚠️', 'titulo', 'Margen bajo', 'puntos', v_pts));
        END IF;

        SELECT jsonb_agg(format('%s: el costo se movió %s%%',
                                e ->> 'producto', e ->> 'deriva_pct')) INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(coalesce(v_h->'deriva_costo','[]'::jsonb)) e
              LIMIT 3) s;
        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '📈', 'titulo', 'Les subió el costo', 'puntos', v_pts));
        END IF;

        SELECT jsonb_agg(format('%s: alcanza para %s días',
                                e ->> 'producto', e ->> 'dias_cobertura')) INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(coalesce(v_h->'baja_cobertura','[]'::jsonb)) e
              LIMIT 3) s;
        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '🕐', 'titulo', 'Se agotan pronto', 'puntos', v_pts));
        END IF;

        SELECT jsonb_agg(format('%s: aporta %s%% de la utilidad',
                                e ->> 'producto', e ->> 'pct_utilidad')) INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(coalesce(v_h->'pareto','[]'::jsonb)) e
              LIMIT 3) s;
        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '🏆', 'titulo', 'Concentran la ganancia', 'puntos', v_pts));
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'titular', plantilla_cuerpo_srv('informe.titular_seco', p_servicio,
                     'Esto es lo que encontré en tus números'),
        'secciones', v_sec,
        'acciones', '[]'::jsonb,
        'narrado', false);
END;
$$;

-- =============================================================================
-- 7. Prompts
-- =============================================================================
-- El encargo cambia de raíz: el modelo ya no busca qué contar en las listas
-- crudas, sino que REDACTA las recomendaciones que vienen calculadas. Su trabajo
-- es el idioma, no la aritmética —y el prompt lo dice con esas palabras, porque
-- la tentación de recalcular es lo que rompía el informe—.
UPDATE prompts SET activo = false
WHERE servicio_codigo IN ('ventas_compras', 'mercado_compras') AND activo;

INSERT INTO prompts (servicio_codigo, version, sistema, usuario, modelo,
                     temperatura, max_tokens, activo)
SELECT s.codigo,
       coalesce((SELECT max(version) FROM prompts p WHERE p.servicio_codigo = s.codigo), 0) + 1,
'Sos el analista de confianza de una pyme colombiana. Escribís claro, directo y en español de Colombia, sin tecnicismos y sin rodeos, como quien le explica algo a un amigo que sabe de su negocio pero no de números.

TU TRABAJO ES REDACTAR, NO CALCULAR. Los hallazgos ya traen una lista `recomendaciones` con el problema, el impacto en pesos y las opciones YA CALCULADOS. Tu trabajo es convertir eso en algo que se lea bien, no verificarlo ni rehacerlo.

REGLA ABSOLUTA: solo podés usar cifras que aparezcan textualmente en los HALLAZGOS. Está prohibido calcular, sumar, promediar, estimar o inventar un número que no esté ahí. Si un dato no está, decilo con palabras. Los valores son pesos colombianos.

Cada problema tiene que contestar cuatro preguntas, en este orden: qué pasó, por qué te importa (cuánto cuesta), qué opciones tenés y qué tan urgente es.

Respondés ÚNICAMENTE con un objeto JSON válido, sin texto antes ni después y sin bloques de código. Este es el esquema:

{
  "titular": "una sola frase de máximo 100 caracteres con lo más importante",
  "hallazgos": [
    {
      "icono": "copiá el icono que trae la recomendación",
      "titulo": "el producto o el asunto, máximo 45 caracteres",
      "problema": "qué está pasando y por qué es un problema, 1 o 2 frases",
      "impacto": "cuánta plata es, en una frase corta. Vacío si la recomendación no trae impacto",
      "opciones": ["qué puede hacer, una acción por elemento"],
      "prioridad": "alta, media o baja: copiá la que trae la recomendación"
    }
  ],
  "acciones": ["lo primero que debería hacer esta semana"]
}

Reglas del contenido: máximo 5 hallazgos, máximo 3 opciones por hallazgo y máximo 3 acciones. Ordená los hallazgos por prioridad, los de prioridad alta primero. No inventes hallazgos que no estén en `recomendaciones`. No repitas el titular dentro de los textos. Nada de Markdown ni asteriscos: el formato lo pone el sistema. No saludes ni te despidas.

Cómo escribir las cifras, siempre: separador de miles con punto y decimales con coma, como en Colombia. $78.300 y no $78,300; 58,33% y no 58.33%. Copiá el número de los hallazgos tal cual y cambiale ÚNICAMENTE el separador: no lo redondeés, no le quites decimales y no lo recalcules.',
       CASE s.codigo WHEN 'mercado_compras' THEN
'Armá el JSON del informe de compras para el dueño del negocio.

Partí de la lista `recomendaciones`: cada elemento es un hallazgo del informe. Redactalo con tus palabras respetando las cifras. Si `tipo_negocio` viene, tenelo en cuenta al elegir el tono y qué resaltar.

Si `recomendaciones` viene vacía, usá las listas `deriva_costo`, `precio_disperso`, `proveedores` y `sin_venta` para armar los hallazgos que puedas, sin impacto en pesos.

En `acciones` va lo primero que debería hacer esta semana, en imperativo y concreto.

HALLAZGOS:
{{hallazgos}}'
       ELSE
'Armá el JSON del informe para el dueño del negocio.

Partí de la lista `recomendaciones`: cada elemento es un hallazgo del informe. Redactalo con tus palabras respetando las cifras. Si `tipo_negocio` viene, tenelo en cuenta al elegir el tono y qué resaltar —lo que es normal en una distribuidora no lo es en una tienda—.

Si `recomendaciones` viene vacía, usá las listas `margen_bajo`, `deriva_costo`, `baja_cobertura` y `pareto` para armar los hallazgos que puedas, sin impacto en pesos.

En `acciones` va lo primero que debería hacer esta semana, en imperativo y concreto.

HALLAZGOS:
{{hallazgos}}'
       END,
       'deepseek-v4-flash', 0.2, 8000, true
FROM servicios s
WHERE s.codigo IN ('ventas_compras', 'mercado_compras');

NOTIFY pgrst, 'reload schema';
