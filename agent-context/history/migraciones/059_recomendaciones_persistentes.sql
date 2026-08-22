-- 059_recomendaciones_persistentes.sql — una recomendación deja de ser un
-- renglón de un informe y pasa a ser algo que se le dijo al dueño.
--
-- R-III dice: "una recomendación persiste después de la ejecución que la
-- produjo y puede evaluarse más tarde". Hoy no se cumple. `recomendaciones_
-- negocio` calcula, el informe las muestra, y se tiran. Consecuencias:
--
--   * Chasqui repite el mismo consejo cada mes sin saber que ya lo dio.
--   * No puede decir "esto te lo dije en marzo y sigue igual".
--   * No puede saber si algo se arregló, y por lo tanto no puede felicitar,
--     ni aprender, ni medir si sirvió de algo.
--   * D1 (los botones "Ya lo hice" / "No aplica") no tiene contra qué escribir.
--
-- LA IDENTIDAD DE UNA RECOMENDACIÓN
--
-- Es `(negocio, regla, objeto)`. "El costo de ACEITE PREMIER subió" es la misma
-- recomendación en marzo y en abril; "el costo de ARROZ subió" es otra. Por eso
-- las seis CTEs publican ahora `clave_objeto` —`producto:<id>` o
-- `proveedor:<nombre>`—: hasta acá lo único que identificaba a una recomendación
-- era el nombre del producto en `titulo`, que ni es estable ni es único.
--
-- Una recomendación cerrada que vuelve a detectarse abre una fila NUEVA, no
-- reabre la vieja. Es a propósito: "te lo dije, lo arreglaste, y volvió" es una
-- historia que el producto va a querer contar, y se pierde si se pisa la fila.
-- Lo garantiza un índice único parcial sobre las abiertas.
--
-- LOS DOS EJES, SEPARADOS DESDE EL DISEÑO
--
-- `estado` responde **¿qué pasó con la recomendación?** — nueva, vigente,
-- resuelta, ignorada, caducada. NO responde "¿sirvió?". Son ejes distintos:
-- "aplicar el precio sugerido" puede quedar ejecutada por el usuario y aun así
-- dar un resultado positivo, neutro o negativo.
--
-- El eje de resultado lo necesita D3, no B2. Pero el modelo tiene que dejarlo
-- entrar sin remodelar nada, así que la columna `resultado` queda creada, en
-- NULL y con su CHECK. Esta migración no la escribe nunca. Está para que a
-- nadie se le ocurra meter "sirvio"/"no_sirvio" dentro de `estado`, que es
-- exactamente el error que el roadmap manda evitar.
--
-- POR QUÉ `recomendaciones_negocio` SIGUE SIENDO PURA
--
-- El roadmap dice "pasa de función pura a función + upsert". Se implementa
-- como función pura + `recomendaciones_registrar`, que la llama y escribe, por
-- tres razones concretas:
--
--   1. `recomendaciones_negocio` es STABLE y la llama `hallazgos_generar`, que
--      también lo es, y a esa la llama `ejecucion_preparar`. Volverla VOLATILE
--      obliga a desmarcar toda la cadena.
--   2. Preguntar no debería escribir. El portal y `/pendientes` pueden querer
--      previsualizar recomendaciones sin registrar que se hicieron.
--   3. Probarla dejaría de ser gratis: hoy se puede correr contra producción
--      sin efectos, y el banco de pruebas depende de eso.
--
-- El efecto buscado —que lo detectado quede registrado— se cumple igual: el
-- registro corre en `ejecucion_cerrar`, en el mismo lugar donde B1 toma el
-- snapshot, y por la misma razón: es cuando de verdad se le entregó algo al
-- dueño.

-- =============================================================================
-- 1. La tabla
-- =============================================================================
CREATE TABLE IF NOT EXISTS recomendaciones (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    negocio_id    bigint NOT NULL REFERENCES negocios(id),
    regla         text   NOT NULL,   -- costo|proveedor|margen|agota|quieto|dependencia
    clave_objeto  text   NOT NULL,   -- producto:<id> | proveedor:<nombre>
    titulo        text   NOT NULL,
    problema      text,
    impacto       text,              -- el texto en pesos que vio el dueño
    impacto_mes   numeric,           -- el número, para comparar entre periodos
    impacto_tipo  text,              -- mensual | unico | capital  (055)
    prioridad     text,              -- alta | media | baja
    opciones      jsonb NOT NULL DEFAULT '[]'::jsonb,
    origen_stock  text,              -- 054: si se apoyó en un stock estimado

    -- --- Eje 1: qué pasó con la recomendación --------------------------------
    estado        text NOT NULL DEFAULT 'nueva'
                  CHECK (estado IN ('nueva','vigente','resuelta','ignorada','caducada')),
    -- Quién la cerró. Distingue "el dato dice que se arregló" de "el dueño dijo
    -- que ya lo hizo", que no son lo mismo aunque terminen en el mismo estado.
    cerrada_por   text CHECK (cerrada_por IN ('dato','accion_usuario','sin_datos')),

    -- --- Eje 2: si sirvió. Lo llena D3; B2 nunca lo escribe. -----------------
    resultado     text CHECK (resultado IN ('positivo','neutro','negativo')),

    detectada_en  timestamptz NOT NULL DEFAULT now(),
    vista_en      timestamptz,       -- cuándo llegó a un informe de verdad
    revisada_en   timestamptz NOT NULL DEFAULT now(),  -- último recálculo que la vio
    cerrada_en    timestamptz,
    veces_vista   int NOT NULL DEFAULT 0,
    ejecucion_id  bigint REFERENCES ejecuciones(id),   -- la que la detectó primero

    CHECK ((estado IN ('nueva','vigente')) = (cerrada_en IS NULL))
);

COMMENT ON TABLE recomendaciones IS
  'Lo que Chasqui le recomendó a un negocio y qué pasó después (R-III). '
  'La identidad es (negocio_id, regla, clave_objeto) mientras está abierta; '
  'un problema que vuelve tras cerrarse abre una fila nueva.';

COMMENT ON COLUMN recomendaciones.estado IS
  'Eje de EJECUCIÓN, no de resultado. nueva = detectada, todavía no mostrada · '
  'vigente = ya se mostró y sigue detectándose · resuelta = el problema ya no '
  'está · ignorada = el dueño dijo que no aplica · caducada = dejó de poder '
  'evaluarse porque el objeto desapareció de los datos.';

COMMENT ON COLUMN recomendaciones.resultado IS
  'Eje de RESULTADO empresarial, independiente de estado. Lo escribe D3 al '
  'contrastar contra el periodo siguiente. B2 lo deja siempre en NULL.';

-- Una sola recomendación ABIERTA por problema. Las cerradas se acumulan: son la
-- historia, y sin ellas no se puede decir "esto ya te había pasado".
CREATE UNIQUE INDEX IF NOT EXISTS uq_recomendacion_abierta
    ON recomendaciones (negocio_id, regla, clave_objeto)
    WHERE estado IN ('nueva','vigente');

CREATE INDEX IF NOT EXISTS idx_recomendaciones_negocio
    ON recomendaciones (negocio_id, estado, detectada_en DESC);

-- =============================================================================
-- 2. El motor de reglas aprende a decir de qué habla
-- =============================================================================
-- Copia de la versión de 055/057 con dos cambios y nada más:
--
--   a) `clave_objeto` en las seis CTEs del UNION ALL (posicional, C5).
--   b) El parámetro `p_registro`. En false —el modo de siempre— devuelve
--      exactamente lo mismo que antes, byte a byte. En true devuelve TODO lo
--      detectado, sin los topes, y con la identidad de cada recomendación.
--
-- El modo informe no cambia a propósito: ese JSON es lo que ve el modelo y lo
-- que audita `validar_cifras`, y no tiene por qué enterarse de una clave
-- interna como 'producto:9'.
-- OJO: `CREATE OR REPLACE` con una aridad distinta NO reemplaza, crea una
-- función más. Con las dos vivas, `recomendaciones_negocio(7)` queda ambigua y
-- revienta en tiempo de ejecución —incluida la llamada de `hallazgos_generar`,
-- o sea el informe entero—. La de un argumento se da de baja explícitamente: la
-- nueva la cubre con su valor por defecto.
DROP FUNCTION IF EXISTS recomendaciones_negocio(bigint);

CREATE OR REPLACE FUNCTION recomendaciones_negocio(p_negocio_id bigint,
                                                   p_registro boolean DEFAULT false)
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
    -- >>> 055: la vara propia de cada tipo de impacto.
    v_pri_alta_u   numeric := coalesce((parametro(p_negocio_id,'prioridad_alta_unico_pct'))::text::numeric, 10);
    v_pri_media_u  numeric := coalesce((parametro(p_negocio_id,'prioridad_media_unico_pct'))::text::numeric, 3);
    v_pri_alta_k   numeric := coalesce((parametro(p_negocio_id,'prioridad_alta_capital_pct'))::text::numeric, 50);
    v_pri_media_k  numeric := coalesce((parametro(p_negocio_id,'prioridad_media_capital_pct'))::text::numeric, 20);
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
    -- Tipo `mensual`: el sobrecosto se repite en cada compra futura.
    -- Las opciones se arman con unnest + agregado, no con jsonb_strip_nulls:
    -- strip_nulls solo borra campos NULL de OBJETOS, no elementos de un array,
    -- así que una opción que no aplica dejaría un `null` suelto en la lista.
    r_costo AS (
        SELECT 'costo' AS regla, ('producto:' || d.producto_id) AS clave_objeto,
               '📈' AS icono, p.nombre_canonico AS titulo,
               round(coalesce(d.costo_fin - d.costo_ini, 0)
                     * coalesce(b.u_compradas, 0) / v_meses) AS impacto_mes,
               'mensual'::text AS impacto_tipo,
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
    -- Tipo `mensual`: la diferencia se paga en cada compra mientras no se cambie.
    r_proveedor AS (
        SELECT 'proveedor' AS regla, ('producto:' || a.producto_id) AS clave_objeto,
               '🧾' AS icono, p.nombre_canonico AS titulo,
               round((a.precio_pagado - a.precio_mejor) * a.u_total / v_meses) AS impacto_mes,
               'mensual'::text AS impacto_tipo,
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
    -- Tipo `mensual`: se deja de ganar en cada venta, mes tras mes.
    r_margen AS (
        SELECT 'margen' AS regla, ('producto:' || mp.producto_id) AS clave_objeto,
               '⚠️' AS icono, mp.nombre_canonico AS titulo,
               round(greatest(round(mp.costo_actual / nullif(1 - v_margen_min/100, 0))
                              - mp.precio_actual, 0)
                     * coalesce(b.u_vendidas, 0) / v_meses) AS impacto_mes,
               'mensual'::text AS impacto_tipo,
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
    -- Tipo `unico`: es el lucro cesante de UN ciclo de entrega. Si se repone a
    -- tiempo no vuelve a ocurrir; no es una fuga mensual.
    -- La cantidad es la del ciclo completo: lo que se vende mientras el
    -- proveedor entrega, más el colchón. Es la cuenta que un tendero no hace y
    -- que decide entre quedarse sin producto o dormir la plata.
    r_agota AS (
        SELECT 'agota' AS regla, ('producto:' || r.producto_id) AS clave_objeto,
               '🕐' AS icono, p.nombre_canonico AS titulo,
               round(r.unidades_por_dia * v_entrega
                     * coalesce(mp.precio_actual, 0)) AS impacto_mes,
               'unico'::text AS impacto_tipo,
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
    -- Tipo `capital`: no es plata que se pierde, es plata que existe y está
    -- inmóvil. Por eso su vara es varias veces más alta que la de una fuga.
    r_quieto AS (
        SELECT 'quieto' AS regla, ('producto:' || r.producto_id) AS clave_objeto,
               CASE WHEN mp.margen_pct >= v_margen_alto THEN '💰' ELSE '📦' END AS icono,
               p.nombre_canonico AS titulo,
               round(bal.balance * coalesce(mp.costo_actual, 0)) AS impacto_mes,
               'capital'::text AS impacto_tipo,
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
    -- Tipo `mensual` con impacto 0: es un riesgo, no una pérdida en curso. El
    -- tipo da igual para la prioridad —entra fija en media— pero se declara
    -- para que ningún consumidor futuro tenga que tratarla como excepción.
    gasto_prov AS (
        SELECT nullif(btrim(coalesce(m.raw ->> 'proveedor', '')), '') AS proveedor,
               sum(m.valor_total) AS gasto
        FROM mov_visibles m
        WHERE m.negocio_id = p_negocio_id AND m.tipo = 'compra'
        GROUP BY 1
    ),
    r_dependencia AS (
        SELECT 'dependencia' AS regla, ('proveedor:' || g.proveedor) AS clave_objeto,
               '🔎' AS icono, 'Dependés de un solo proveedor' AS titulo,
               0::numeric AS impacto_mes, 'mensual'::text AS impacto_tipo, '' AS impacto_txt,
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
    -- La prioridad sigue siendo el impacto medido contra lo que mueve el
    -- negocio, pero cada tipo tiene su vara (055). La dependencia de proveedor
    -- no tiene impacto calculable y entra fija en media: es un riesgo, no una
    -- pérdida que ya esté ocurriendo.
    --
    -- `relevancia` = cuántas veces la recomendación supera el umbral MEDIA de su
    -- propio tipo. Es lo único comparable entre tipos, y es lo que ordena dentro
    -- de una misma prioridad. Antes ordenaba `impacto_mes` crudo, y un capital
    -- acumulado le ganaba siempre a una fuga mensual por ser un número mayor,
    -- aunque significara menos.
    priorizadas AS (
        SELECT t.regla, t.clave_objeto,
               t.icono, t.titulo, t.problema, t.opciones, t.impacto_txt,
               t.origen_stock, t.impacto_tipo,
               coalesce(t.impacto_mes, 0) AS impacto_mes,
               CASE WHEN t.regla = 'dependencia' THEN 'media'
                    WHEN u.pct >= u.alta  THEN 'alta'
                    WHEN u.pct >= u.media THEN 'media'
                    ELSE 'baja' END AS prioridad,
               CASE WHEN t.regla = 'dependencia' THEN 0
                    ELSE u.pct / greatest(u.media, 0.0001) END AS relevancia,
               -- El tope por regla: lo peor de cada frente, no el ranking de
               -- pesos, que se llena con la regla que más productos toca.
               -- Dentro de una regla el tipo es el mismo, así que acá el monto
               -- crudo sí compara bien.
               row_number() OVER (PARTITION BY t.regla
                                  ORDER BY coalesce(t.impacto_mes, 0) DESC) AS rn
        FROM todas t
        CROSS JOIN LATERAL (
            SELECT coalesce(t.impacto_mes, 0) * 100.0 / v_base_mes AS pct,
                   CASE t.impacto_tipo WHEN 'unico'   THEN v_pri_alta_u
                                       WHEN 'capital' THEN v_pri_alta_k
                                       ELSE v_pri_alta END          AS alta,
                   CASE t.impacto_tipo WHEN 'unico'   THEN v_pri_media_u
                                       WHEN 'capital' THEN v_pri_media_k
                                       ELSE v_pri_media END         AS media
        ) u
        WHERE coalesce(t.titulo, '') <> ''
    ),
    -- >>> 059. Hasta acá el tope (2 por regla, 8 en total) se aplicaba en la
    -- consulta final y lo que quedaba afuera se perdía. Para persistir hace
    -- falta distinguir dos conjuntos que antes eran uno:
    --
    --   lo DETECTADO — todos los problemas que las reglas encontraron.
    --   lo MOSTRADO  — los que entraron al informe después de los topes.
    --
    -- Sin esa distinción, una recomendación abierta que hoy no aparece podría
    -- estar ausente porque el problema se arregló O porque la empujaron fuera
    -- del top 8, y cerrarla como "resuelta" en el segundo caso sería mentir.
    visibles AS (
        SELECT regla, clave_objeto,
               row_number() OVER (
                 ORDER BY CASE prioridad WHEN 'alta' THEN 1 WHEN 'media' THEN 2 ELSE 3 END,
                          relevancia DESC) AS pos
        FROM priorizadas WHERE rn <= 2
    ),
    salida AS (
        SELECT p.*, coalesce(v.pos <= 8, false) AS en_informe
        FROM priorizadas p
        LEFT JOIN visibles v
               ON v.regla = p.regla AND v.clave_objeto = p.clave_objeto
        -- En modo informe sale lo de siempre; en modo registro, todo.
        WHERE p_registro OR coalesce(v.pos, 2147483647) <= 8
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'icono', icono, 'prioridad', prioridad, 'titulo', titulo,
             'problema', problema,
             'impacto', coalesce(impacto_txt, ''),
             'impacto_mes', impacto_mes,
             -- >>> 055: qué clase de impacto es el número de arriba.
             --   mensual — pesos por mes que se van a seguir yendo
             --   unico   — pesos una sola vez, si el evento ocurre
             --   capital — pesos que existen y están inmóviles
             'impacto_tipo', impacto_tipo,
             'opciones', opciones,
             -- >>> 054: de dónde sale el stock con el que se calculó
             -- esto. 'estimado' = comprado menos vendido, sin conteo.
             'origen_stock', origen_stock)
             -- >>> 059: la identidad de la recomendación viaja SOLO en modo
             -- registro. En modo informe el JSON queda como estaba, que es lo
             -- que ve el modelo y lo que audita validar_cifras: no tiene por
             -- qué enterarse de una clave interna como 'producto:9'.
             || CASE WHEN p_registro
                     THEN jsonb_build_object('regla', regla,
                                             'clave_objeto', clave_objeto,
                                             'en_informe', en_informe)
                     ELSE '{}'::jsonb END
             ORDER BY CASE prioridad WHEN 'alta' THEN 1 WHEN 'media' THEN 2 ELSE 3 END,
                      relevancia DESC), '[]'::jsonb)
      INTO v_out
    FROM salida s;

    RETURN v_out;
END;
$$;



-- =============================================================================
-- 3. "Se resolvió" y "lo perdí de vista" no son lo mismo
-- =============================================================================
-- Una recomendación abierta que hoy no se detecta puede serlo por dos razones
-- opuestas, y confundirlas sería mentirle al dueño:
--
--   * El problema se arregló — el costo bajó, el margen subió, el stock se
--     repuso. Las reglas SÍ evaluaron el objeto y no dispararon.
--   * Dejé de poder verlo — el producto no tiene un solo movimiento en la
--     ventana visible, así que ninguna regla lo pudo evaluar. Eso no es
--     haberlo resuelto.
--
-- Esta función es la que los separa.
CREATE OR REPLACE FUNCTION recomendacion_objeto_evaluable(p_negocio_id bigint,
                                                          p_clave text)
RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT CASE
      WHEN p_clave LIKE 'producto:%' THEN EXISTS (
             SELECT 1 FROM mov_visibles
              WHERE negocio_id = p_negocio_id
                AND producto_id = nullif(split_part(p_clave, ':', 2), '')::bigint)
      WHEN p_clave LIKE 'proveedor:%' THEN EXISTS (
             SELECT 1 FROM mov_visibles
              WHERE negocio_id = p_negocio_id AND tipo = 'compra'
                AND btrim(coalesce(raw ->> 'proveedor', '')) = substring(p_clave FROM 11))
      ELSE false
    END;
$$;

-- =============================================================================
-- 4. El registro
-- =============================================================================
-- Cuatro pasos en una pasada, en este orden:
--
--   1. Refrescar las que ya estaban abiertas y se siguen detectando.
--   2. Dar de alta las detectadas que no tenían fila abierta.
--   3. Cerrar las abiertas que hoy no se detectan (resuelta o caducada).
--   4. Marcar como vistas las que llegaron al informe.
--
-- El 1 va antes que el 2 para no tener que distinguir después cuáles acaba de
-- insertar esta misma corrida.
--
-- `recomendaciones_negocio` se llama en modo REGISTRO, con todo lo detectado y
-- sin los topes. Si se usara la salida del informe, una recomendación empujada
-- fuera del top 8 se cerraría como "resuelta" sin que nada se hubiera arreglado.
CREATE OR REPLACE FUNCTION recomendaciones_registrar(p_negocio_id   bigint,
                                                     p_ejecucion_id bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_detectadas jsonb;
    v_nuevas     int := 0;
    v_seguian    int := 0;
    v_resueltas  int := 0;
    v_caducadas  int := 0;
    v_vistas     int := 0;
BEGIN
    v_detectadas := recomendaciones_negocio(p_negocio_id, true);


    -- ---- 1. Las que siguen -------------------------------------------------
    -- Se refrescan las cifras: el impacto cambia entre periodos y lo que
    -- interesa mostrar es el de hoy. `detectada_en` NO se toca — es cuándo
    -- empezó el problema, y es media respuesta a "¿desde cuándo vengo así?".
    WITH upd AS (
        UPDATE recomendaciones r
           SET titulo = d.titulo, problema = d.problema, impacto = d.impacto,
               impacto_mes = d.impacto_mes, impacto_tipo = d.impacto_tipo,
               prioridad = d.prioridad, opciones = coalesce(d.opciones, '[]'::jsonb),
               origen_stock = d.origen_stock, revisada_en = now()
          FROM (SELECT * FROM jsonb_to_recordset(v_detectadas) AS e(
                  regla text, clave_objeto text, titulo text, problema text,
                  impacto text, impacto_mes numeric, impacto_tipo text,
                  prioridad text, opciones jsonb, origen_stock text,
                  en_informe boolean)) d
         WHERE r.negocio_id = p_negocio_id AND r.regla = d.regla
           AND r.clave_objeto = d.clave_objeto
           AND r.estado IN ('nueva','vigente')
        RETURNING 1)
    SELECT count(*) INTO v_seguian FROM upd;

    -- ---- 2. Las que aparecen por primera vez -------------------------------
    WITH ins AS (
        INSERT INTO recomendaciones (negocio_id, regla, clave_objeto, titulo,
                 problema, impacto, impacto_mes, impacto_tipo, prioridad,
                 opciones, origen_stock, ejecucion_id)
        SELECT p_negocio_id, d.regla, d.clave_objeto, d.titulo, d.problema,
               d.impacto, d.impacto_mes, d.impacto_tipo, d.prioridad,
               coalesce(d.opciones, '[]'::jsonb), d.origen_stock, p_ejecucion_id
        FROM (SELECT * FROM jsonb_to_recordset(v_detectadas) AS e(
                  regla text, clave_objeto text, titulo text, problema text,
                  impacto text, impacto_mes numeric, impacto_tipo text,
                  prioridad text, opciones jsonb, origen_stock text,
                  en_informe boolean)) d
        WHERE NOT EXISTS (
            SELECT 1 FROM recomendaciones r
             WHERE r.negocio_id = p_negocio_id AND r.regla = d.regla
               AND r.clave_objeto = d.clave_objeto
               AND r.estado IN ('nueva','vigente'))
        RETURNING 1)
    SELECT count(*) INTO v_nuevas FROM ins;

    -- ---- 3. Las que ya no están --------------------------------------------
    WITH cerradas AS (
        UPDATE recomendaciones r
           SET estado      = CASE WHEN recomendacion_objeto_evaluable(p_negocio_id, r.clave_objeto)
                                  THEN 'resuelta' ELSE 'caducada' END,
               cerrada_por = CASE WHEN recomendacion_objeto_evaluable(p_negocio_id, r.clave_objeto)
                                  THEN 'dato' ELSE 'sin_datos' END,
               cerrada_en  = now(), revisada_en = now()
         WHERE r.negocio_id = p_negocio_id
           AND r.estado IN ('nueva','vigente')
           -- Basta con esto: el paso 1 solo tocó las que SÍ están detectadas,
           -- así que no hay forma de que una de ellas caiga acá.
           AND NOT EXISTS (SELECT 1 FROM jsonb_to_recordset(v_detectadas)
                                    AS d(regla text, clave_objeto text)
                            WHERE d.regla = r.regla AND d.clave_objeto = r.clave_objeto)
        RETURNING estado)
    SELECT count(*) FILTER (WHERE estado = 'resuelta'),
           count(*) FILTER (WHERE estado = 'caducada')
      INTO v_resueltas, v_caducadas
    FROM cerradas;

    -- ---- 4. Lo que llegó al informe cuenta como visto ----------------------
    -- Solo lo que entró al top 8. Marcar como vista una recomendación que el
    -- dueño nunca leyó dejaría el dato inservible el día que D1 le pregunte
    -- "¿hiciste algo con esto?".
    WITH marcadas AS (
        UPDATE recomendaciones r
           SET estado = 'vigente',
               vista_en = coalesce(r.vista_en, now()),
               veces_vista = r.veces_vista + 1
          FROM (SELECT * FROM jsonb_to_recordset(v_detectadas)
                         AS e(regla text, clave_objeto text, en_informe boolean)) d
         WHERE r.negocio_id = p_negocio_id AND r.regla = d.regla
           AND r.clave_objeto = d.clave_objeto
           AND d.en_informe
           AND r.estado IN ('nueva','vigente')
        RETURNING 1)
    SELECT count(*) INTO v_vistas FROM marcadas;

    RETURN jsonb_build_object('nuevas', v_nuevas, 'seguian', v_seguian,
                              'resueltas', v_resueltas, 'caducadas', v_caducadas,
                              'mostradas', v_vistas);
END;
$$;

-- =============================================================================
-- 5. Se registra al cerrar el análisis
-- =============================================================================
-- Mismo lugar y misma razón que el snapshot de B1: es cuando de verdad se le
-- entregó algo al dueño. Y mismo guardarraíl — si el registro falla, la falla
-- queda anotada y la ejecución se cierra igual. Un informe entregado vale más
-- que una contabilidad perfecta de lo que se recomendó.
CREATE OR REPLACE FUNCTION ejecucion_cerrar(p_ejecucion_id bigint, p_estado text,
                                            p_resultado jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_sesion_id  bigint;
    v_servicio   text;
    v_negocio_id bigint;
    v_chat       bigint;
    v_plantilla  text := 'ejecucion.entregada';
    v_snapshot   bigint;
    v_recos      jsonb;
BEGIN
    UPDATE ejecuciones SET
        estado        = p_estado::estado_ejec,
        texto         = coalesce(p_resultado ->> 'texto', texto),
        tokens_prompt = coalesce((p_resultado ->> 'tokens_prompt')::int, tokens_prompt),
        tokens_salida = coalesce((p_resultado ->> 'tokens_salida')::int, tokens_salida),
        costo         = coalesce((p_resultado ->> 'costo')::numeric, costo),
        pdf           = coalesce(decode(p_resultado ->> 'pdf_base64', 'base64'), pdf),
        error         = p_resultado ->> 'error',
        fin           = now()
    WHERE id = p_ejecucion_id
    RETURNING sesion_id, servicio_codigo, negocio_id
         INTO v_sesion_id, v_servicio, v_negocio_id;

    IF v_sesion_id IS NOT NULL THEN
        SELECT chat_de_usuario(s.usuario_id) INTO v_chat
        FROM sesiones s WHERE s.id = v_sesion_id;

        UPDATE sesiones SET
            estado     = CASE WHEN p_estado = 'completada' THEN 'completada'::estado_sesion
                              ELSE 'fallida'::estado_sesion END,
            cerrada_en = now()
        WHERE id = v_sesion_id;
    END IF;

    IF p_estado = 'completada' AND v_negocio_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM servicios
                    WHERE codigo = v_servicio AND entrada = 'archivos') THEN
        -- >>> 058: la memoria del estado del negocio.
        BEGIN
            v_snapshot := snapshot_tomar(v_negocio_id, 'ejecucion', p_ejecucion_id);
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO fallas (workflow, ejecucion_id, sesion_id, tipo, transitoria, detalle)
            VALUES ('snapshot_tomar', p_ejecucion_id, v_sesion_id, 'permanente', false,
                    jsonb_build_object('mensaje', SQLERRM, 'sqlstate', SQLSTATE));
        END;

        -- >>> 059: la memoria de lo que se le recomendó (R-III).
        BEGIN
            v_recos := recomendaciones_registrar(v_negocio_id, p_ejecucion_id);
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO fallas (workflow, ejecucion_id, sesion_id, tipo, transitoria, detalle)
            VALUES ('recomendaciones_registrar', p_ejecucion_id, v_sesion_id,
                    'permanente', false,
                    jsonb_build_object('mensaje', SQLERRM, 'sqlstate', SQLSTATE));
        END;
    END IF;

    IF EXISTS (SELECT 1 FROM plantillas
                WHERE clave = 'ejecucion.entregada.' || coalesce(v_servicio, '—')
                  AND activo) THEN
        v_plantilla := 'ejecucion.entregada.' || v_servicio;
    END IF;

    RETURN jsonb_build_object('ejecucion_id', p_ejecucion_id, 'estado', p_estado,
                              'chat_id', v_chat, 'servicio_codigo', v_servicio,
                              'plantilla_entrega', v_plantilla,
                              'snapshot_id', v_snapshot,
                              'recomendaciones', v_recos);
END;
$$;

-- =============================================================================
-- 6. Leer la historia
-- =============================================================================
-- El accesor que van a consumir C1 ("¿cómo está mi negocio?" necesita saber qué
-- se recomendó) y D1 (los botones). Acá solo se lee: escribir un estado por
-- decisión del usuario es D1, y esta migración no inventa esa interfaz.
CREATE OR REPLACE FUNCTION recomendaciones_vigentes(p_negocio_id bigint,
                                                    p_limite int DEFAULT 20)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'id', id, 'regla', regla, 'clave_objeto', clave_objeto,
             'titulo', titulo, 'problema', problema, 'impacto', impacto,
             'impacto_mes', impacto_mes, 'impacto_tipo', impacto_tipo,
             'prioridad', prioridad, 'opciones', opciones,
             'origen_stock', origen_stock, 'estado', estado,
             'detectada_en', detectada_en, 'veces_vista', veces_vista,
             -- Cuántos periodos lleva sin resolverse. Es la diferencia entre
             -- "te lo digo por primera vez" y "van cuatro veces".
             'dias_abierta', (current_date - detectada_en::date))
             ORDER BY CASE prioridad WHEN 'alta' THEN 1 WHEN 'media' THEN 2 ELSE 3 END,
                      impacto_mes DESC), '[]'::jsonb)
    FROM (SELECT * FROM recomendaciones
           WHERE negocio_id = p_negocio_id AND estado IN ('nueva','vigente')
           ORDER BY CASE prioridad WHEN 'alta' THEN 1 WHEN 'media' THEN 2 ELSE 3 END,
                    impacto_mes DESC
           LIMIT p_limite) r;
$$;

CREATE OR REPLACE FUNCTION portal_recomendaciones(p_limite int DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    RETURN jsonb_build_object(
      'vigentes', recomendaciones_vigentes(v_negocio, p_limite),
      -- Las cerradas son la mitad interesante: "esto te lo dije y se arregló".
      'cerradas', coalesce((
         SELECT jsonb_agg(jsonb_build_object(
                  'id', id, 'titulo', titulo, 'impacto', impacto,
                  'estado', estado, 'cerrada_por', cerrada_por,
                  'detectada_en', detectada_en, 'cerrada_en', cerrada_en)
                  ORDER BY cerrada_en DESC)
         FROM (SELECT * FROM recomendaciones
                WHERE negocio_id = v_negocio AND estado NOT IN ('nueva','vigente')
                ORDER BY cerrada_en DESC LIMIT p_limite) c), '[]'::jsonb));
END;
$$;

GRANT EXECUTE ON FUNCTION portal_recomendaciones(int) TO portal_usuario;

NOTIFY pgrst, 'reload schema';
