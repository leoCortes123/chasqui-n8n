-- 058_snapshot_negocio.sql — Chasqui empieza a acordarse.
--
-- Hasta acá el sistema mira SIEMPRE el presente. `hallazgos_generar` calcula
-- sobre los movimientos de hoy, entrega el informe, y lo que midió se pierde:
-- la próxima corrida vuelve a partir de cero. Eso hace imposible toda la
-- prioridad 3 del roadmap —"el margen se deterioró dos periodos seguidos",
-- "este proveedor te subió tres veces", "vendiste menos que el mismo mes del
-- año pasado"— y también la pregunta que da nombre al producto: si Chasqui no
-- recuerda cómo estaba el negocio, no puede decir si va mejor o peor.
--
-- QUÉ ES UN SNAPSHOT, Y QUÉ NO ES
--
-- Es **estado empresarial**, no una copia del informe. Guarda números
-- estructurados: márgenes por producto, coberturas, gasto por proveedor, las
-- cinco notas de salud, totales del periodo. NO guarda texto narrado, ni HTML,
-- ni la estructura de secciones del informe.
--
-- La diferencia importa porque el informe va a cambiar de diseño varias veces y
-- los snapshots tienen que seguir siendo comparables entre sí. Un snapshot
-- tomado hoy tiene que poder compararse con uno de dentro de un año aunque para
-- entonces el informe no se parezca en nada al de ahora.
--
-- POR QUÉ NO ALCANZA CON `ejecuciones.hallazgos` (C4)
--
-- Esa columna ya persiste el JSON completo de cada corrida desde la 001, y es
-- buen material: de ahí sale el backfill del final de esta migración. Pero no
-- sirve COMO snapshot, por dos razones:
--
--   1. Su forma cambió cuatro veces (025, 029, 043, 047) y va a volver a
--      cambiar: es la entrada de un prompt, no un contrato de datos.
--   2. Es lo que el informe necesitaba ese día, no lo que el negocio era. Trae
--      solo los productos que dispararon una regla —los de margen bajo, los de
--      cobertura corta— y no el resto, que es justamente contra lo que hay que
--      comparar para ver un deterioro.
--
-- De ahí la columna `version`: el snapshot SÍ es un contrato, y cuando cambie
-- se sabrá cuál es cuál en vez de tener que adivinar por la forma.
--
-- LO QUE ESTA MIGRACIÓN NO HACE, A PROPÓSITO
--
-- No guarda recomendaciones. Persistirlas y seguirlas es B2, con su propio
-- modelo de estados, y mezclarlas acá obligaría a remodelar después. El
-- snapshot dice cómo estaba el negocio; B2 dirá qué se le recomendó y qué pasó.
--
-- Tampoco calcula ninguna comparación: eso es B3. Acá solo se deja el material.

-- =============================================================================
-- 1. La versión del contrato
-- =============================================================================
-- Vive en una función y no en un literal repartido por el archivo para que
-- subirla sea un solo cambio, y para que B3 pueda preguntar contra qué versión
-- está comparando en vez de deducirlo.
--
-- v1 = el `metricas` que arma `snapshot_tomar` más abajo.
CREATE OR REPLACE FUNCTION snapshot_version() RETURNS int
LANGUAGE sql IMMUTABLE AS $$ SELECT 1 $$;

COMMENT ON FUNCTION snapshot_version() IS
  'Versión del contrato de snapshots_negocio.metricas. Subirla al cambiar la '
  'forma de metricas; los snapshots viejos conservan la suya y siguen siendo '
  'legibles.';

-- =============================================================================
-- 2. La tabla
-- =============================================================================
CREATE TABLE IF NOT EXISTS snapshots_negocio (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    negocio_id   bigint NOT NULL REFERENCES negocios(id),
    fecha        date   NOT NULL DEFAULT current_date,
    version      int    NOT NULL,
    -- Ventana de datos que el snapshot está describiendo. No es lo mismo que
    -- `fecha`: un snapshot tomado hoy puede describir enero-marzo.
    periodo      daterange,
    -- Las cinco notas + el índice, tal cual las devolvió salud_negocio ese día.
    -- Se guarda aparte de `metricas` porque es lo que más se va a consultar y
    -- porque su forma es estable desde la 047.
    salud        jsonb,
    metricas     jsonb NOT NULL,
    origen       text   NOT NULL,   -- ejecucion | backfill | manual
    ejecucion_id bigint REFERENCES ejecuciones(id),
    creado_en    timestamptz NOT NULL DEFAULT now(),
    -- Un snapshot por negocio y día. Dos análisis el mismo día no son dos
    -- estados distintos del negocio: el segundo corrige al primero. Y sin esto,
    -- las comparaciones de B3 tendrían que decidir cuál de los dos vale.
    CONSTRAINT uq_snapshot_dia UNIQUE (negocio_id, fecha)
);

COMMENT ON TABLE snapshots_negocio IS
  'Estado empresarial en una fecha: números estructurados y versionados, nunca '
  'texto narrado. Es la memoria sobre la que B3 compara periodos.';

COMMENT ON COLUMN snapshots_negocio.origen IS
  'ejecucion = lo tomó una corrida al cerrar · backfill = reconstruido desde '
  'ejecuciones.hallazgos, necesariamente parcial · manual = lo pidió alguien.';

-- El acceso natural es "el último antes de X" para un negocio.
CREATE INDEX IF NOT EXISTS idx_snapshots_negocio_fecha
    ON snapshots_negocio (negocio_id, fecha DESC);

-- Los umbrales con los que se midió, todos juntos. No sirve `parametro()`,
-- que devuelve una clave: hace falta el conjunto. La precedencia es la de
-- siempre —la fila del negocio le gana a la global— y por eso el DISTINCT ON
-- va ordenado: sin él, `jsonb_object_agg` se quedaría con cualquiera de las dos
-- y el snapshot registraría un umbral que no fue el que se usó.
CREATE OR REPLACE FUNCTION snapshot_umbrales(p_negocio_id bigint)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT coalesce(jsonb_object_agg(clave, valor), '{}'::jsonb)
    FROM (SELECT DISTINCT ON (clave) clave, valor
          FROM parametros
          WHERE negocio_id = p_negocio_id OR negocio_id IS NULL
          ORDER BY clave, negocio_id NULLS LAST) t;
$$;

-- =============================================================================
-- 3. Tomar el snapshot
-- =============================================================================
-- Se calcula desde las vistas, NO desde el JSON de hallazgos. Es la decisión
-- central de esta migración: los hallazgos son lo que el informe necesitaba,
-- las vistas son lo que el negocio es.
--
-- Todo lo que mide sale de `mov_visibles`, o sea de la ventana que el plan deja
-- analizar (053). Es lo correcto: el snapshot tiene que registrar lo que el
-- sistema efectivamente vio, que es sobre lo que opinó. Si el negocio amplía el
-- plan, los snapshots viejos siguen contando la verdad de su momento y los
-- nuevos ven más historia — y esa diferencia se lee en `periodo`.
CREATE OR REPLACE FUNCTION snapshot_tomar(p_negocio_id   bigint,
                                          p_origen       text DEFAULT 'manual',
                                          p_ejecucion_id bigint DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    v_desde    date;
    v_hasta    date;
    v_meses    numeric;
    v_metricas jsonb;
    v_id       bigint;
BEGIN
    SELECT min(fecha), max(fecha) INTO v_desde, v_hasta
    FROM mov_visibles WHERE negocio_id = p_negocio_id AND fecha IS NOT NULL;

    -- Sin un solo movimiento fechado no hay estado que fotografiar. Devolver
    -- NULL en vez de una fila vacía: un snapshot de la nada haría creer a B3
    -- que hubo un periodo medido en el que todo valía cero.
    IF v_desde IS NULL THEN
        RETURN NULL;
    END IF;

    -- La misma ventana con la que `recomendaciones_negocio` escala lo mensual.
    v_meses := greatest((v_hasta - v_desde)::numeric / 30.0, 1);

    SELECT jsonb_build_object(
      -- --- Totales del periodo ------------------------------------------------
      'totales', (SELECT jsonb_build_object(
                    'ventas',   round(coalesce(sum(valor_total) FILTER (WHERE tipo = 'venta'), 0)),
                    'compras',  round(coalesce(sum(valor_total) FILTER (WHERE tipo = 'compra'), 0)),
                    'movimientos_venta',  count(*) FILTER (WHERE tipo = 'venta'),
                    'movimientos_compra', count(*) FILTER (WHERE tipo = 'compra'),
                    'meses', round(v_meses, 2),
                    -- Lo que mueve el negocio en un mes: es el denominador con
                    -- el que se priorizan las recomendaciones, así que sin él un
                    -- impacto de dos snapshots distintos no es comparable.
                    'base_mes', round(greatest(
                        coalesce(sum(valor_total) FILTER (WHERE tipo = 'venta'),
                                 sum(valor_total) FILTER (WHERE tipo = 'compra'), 0) / v_meses, 1)))
                  FROM mov_visibles WHERE negocio_id = p_negocio_id),

      -- --- Resumen de catálogo ------------------------------------------------
      'productos', (SELECT jsonb_build_object(
                      'total', count(*),
                      'con_precio', count(*) FILTER (WHERE precio_actual IS NOT NULL),
                      'margen_promedio_pct', round(avg(margen_pct), 2))
                    FROM v_margen_producto WHERE negocio_id = p_negocio_id),

      -- --- Margen por producto (TODOS, no solo los que disparan regla) --------
      -- Guardar solo los de margen bajo sería guardar el informe otra vez. Para
      -- ver un deterioro hay que tener también los que hoy están bien.
      'margenes', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                     'producto_id', producto_id, 'nombre', nombre_canonico,
                     'costo', costo_actual, 'precio', precio_actual,
                     'margen_pct', margen_pct) ORDER BY producto_id), '[]'::jsonb)
                   FROM v_margen_producto WHERE negocio_id = p_negocio_id),

      -- --- Cobertura y stock por producto -------------------------------------
      'coberturas', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                       'producto_id', r.producto_id, 'nombre', p.nombre_canonico,
                       'dias_cobertura', r.dias_cobertura,
                       'unidades_por_dia', r.unidades_por_dia,
                       'balance', b.balance,
                       -- 054: sin esto, comparar dos coberturas puede ser
                       -- comparar un conteo real contra una estimación.
                       'origen_stock', r.origen_stock) ORDER BY r.producto_id), '[]'::jsonb)
                     FROM v_rotacion_producto r
                     JOIN productos p ON p.id = r.producto_id
                     LEFT JOIN v_balance_unidades b
                            ON b.producto_id = r.producto_id AND b.negocio_id = r.negocio_id
                     WHERE r.negocio_id = p_negocio_id),

      -- --- Deriva de costo ----------------------------------------------------
      'derivas', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                    'producto_id', producto_id, 'costo_ini', costo_ini,
                    'costo_fin', costo_fin, 'deriva_pct', deriva_pct)
                    ORDER BY producto_id), '[]'::jsonb)
                  FROM v_deriva_costo WHERE negocio_id = p_negocio_id),

      -- --- Gasto por proveedor ------------------------------------------------
      -- El % va calculado y no derivado al leer: si mañana entra una compra
      -- vieja, el gasto total del periodo cambia, y el snapshot tiene que
      -- seguir diciendo qué concentración se midió ESE día.
      'proveedores', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'proveedor', prov, 'gasto', round(gasto), 'pct', pct)
                        ORDER BY gasto DESC), '[]'::jsonb)
                      FROM (SELECT prov, gasto,
                                   round(gasto * 100.0 / nullif(sum(gasto) OVER (), 0), 1) AS pct
                            FROM (SELECT nullif(btrim(coalesce(raw ->> 'proveedor','')),'') AS prov,
                                         sum(valor_total) AS gasto
                                  FROM mov_visibles
                                  WHERE negocio_id = p_negocio_id AND tipo = 'compra'
                                    AND nullif(btrim(coalesce(raw ->> 'proveedor','')),'') IS NOT NULL
                                  GROUP BY 1) g0) g),

      -- --- Precio pagado por producto y proveedor -----------------------------
      -- Es lo que hace posible "este proveedor te subió tres veces en el año".
      -- Sin el par (producto, proveedor) solo se ve el gasto agregado, que sube
      -- también cuando simplemente comprás más.
      'precios_proveedor', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                              'producto_id', producto_id, 'proveedor', prov,
                              'precio_prom', round(precio_prom, 2), 'unidades', u)
                              ORDER BY producto_id, prov), '[]'::jsonb)
                            FROM (SELECT producto_id,
                                         nullif(btrim(coalesce(raw ->> 'proveedor','')),'') AS prov,
                                         sum(cantidad) AS u,
                                         sum(valor_total) / nullif(sum(cantidad), 0) AS precio_prom
                                  FROM mov_visibles
                                  WHERE negocio_id = p_negocio_id AND tipo = 'compra'
                                    AND producto_id IS NOT NULL AND cantidad > 0
                                    AND nullif(btrim(coalesce(raw ->> 'proveedor','')),'') IS NOT NULL
                                  GROUP BY 1, 2) pp),

      -- --- Unidades vendidas por producto -------------------------------------
      -- Para "este producto dejó de venderse", que se detecta comparando contra
      -- un snapshot anterior donde sí figuraba.
      'ventas_producto', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                            'producto_id', producto_id, 'unidades', round(u, 3),
                            'importe', round(imp)) ORDER BY producto_id), '[]'::jsonb)
                          FROM (SELECT producto_id, sum(cantidad) AS u, sum(valor_total) AS imp
                                FROM mov_visibles
                                WHERE negocio_id = p_negocio_id AND tipo = 'venta'
                                  AND producto_id IS NOT NULL
                                GROUP BY 1) vp),

      -- --- Concentración de utilidad ------------------------------------------
      'pareto', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                   'producto_id', producto_id, 'utilidad', round(utilidad),
                   'pct_utilidad', pct_utilidad, 'pct_acumulado', pct_acumulado)
                   ORDER BY utilidad DESC), '[]'::jsonb)
                 FROM v_pareto_utilidad WHERE negocio_id = p_negocio_id),

      -- --- Calidad del dato sobre el que se midió todo esto -------------------
      -- Un snapshot con el 40% de la plata sin producto resuelto (057) no es
      -- comparable con uno limpio, y quien compare tiene que poder saberlo.
      'calidad', (SELECT jsonb_build_object(
                    'movs_sin_producto', movs_sin_producto,
                    'dinero_sin_producto', dinero_sin_producto,
                    'pct_dinero_fuera', coalesce(pct_dinero_fuera, 0),
                    'productos_stock_estimado', (
                      SELECT count(*) FROM v_balance_unidades
                       WHERE negocio_id = p_negocio_id AND origen_stock = 'estimado'))
                  FROM v_calidad_matching WHERE negocio_id = p_negocio_id),

      -- --- Con qué umbrales se midió ------------------------------------------
      -- Los umbrales son por negocio y se pueden cambiar. Una nota de salud que
      -- baja porque alguien movió `margen_minimo_pct` no es un deterioro del
      -- negocio, y sin esto no habría forma de distinguirlo.
      'umbrales', snapshot_umbrales(p_negocio_id)
    ) INTO v_metricas;

    INSERT INTO snapshots_negocio (negocio_id, fecha, version, periodo, salud,
                                   metricas, origen, ejecucion_id)
    VALUES (p_negocio_id, current_date, snapshot_version(),
            daterange(v_desde, v_hasta, '[]'),
            salud_negocio(p_negocio_id), v_metricas, p_origen, p_ejecucion_id)
    ON CONFLICT ON CONSTRAINT uq_snapshot_dia DO UPDATE
      SET version = EXCLUDED.version, periodo = EXCLUDED.periodo,
          salud = EXCLUDED.salud, metricas = EXCLUDED.metricas,
          origen = EXCLUDED.origen, ejecucion_id = EXCLUDED.ejecucion_id,
          creado_en = now()
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

-- =============================================================================
-- 4. Leer el snapshot anterior
-- =============================================================================
-- Es el accesor que consume B3. Vive acá porque es parte del contrato del
-- snapshot: quien lo escribe define cómo se lee "el de antes".
--
-- "Anterior" es estrictamente anterior por fecha, no por id: dos snapshots del
-- mismo día no existen (uq_snapshot_dia), y comparar contra el de hoy mismo
-- sería compararse consigo mismo.
CREATE OR REPLACE FUNCTION snapshot_anterior(p_negocio_id bigint,
                                             p_antes_de date DEFAULT current_date)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
             'id', id, 'fecha', fecha, 'version', version,
             'periodo_desde', lower(periodo), 'periodo_hasta', upper(periodo),
             'origen', origen, 'salud', salud, 'metricas', metricas)
    FROM snapshots_negocio
    WHERE negocio_id = p_negocio_id AND fecha < p_antes_de
    ORDER BY fecha DESC
    LIMIT 1;
$$;

COMMENT ON FUNCTION snapshot_anterior(bigint, date) IS
  'El último estado registrado ANTES de la fecha dada. Es la entrada de las '
  'reglas comparativas (B3). Devuelve NULL si el negocio no tiene historia: '
  'una regla comparativa sin snapshot previo no dispara, no inventa.';

-- =============================================================================
-- 5. El snapshot se toma solo al cerrar un análisis
-- =============================================================================
-- Al cerrar y no al preparar: si la corrida falló, el estado no se registró.
-- Y solo para los servicios de archivos —los que analizan el negocio—, no para
-- `consulta`: preguntar algo no cambia el estado empresarial, y un snapshot por
-- cada pregunta llenaría la historia de ruido sin agregar información.
--
-- El snapshot NO puede tumbar la entrega del informe. Si algo falla al tomarlo,
-- se registra en `fallas` y la ejecución se cierra igual: un informe entregado
-- vale más que una foto perfecta.
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

    -- >>> 058: la memoria del negocio.
    IF p_estado = 'completada' AND v_negocio_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM servicios
                    WHERE codigo = v_servicio AND entrada = 'archivos') THEN
        BEGIN
            v_snapshot := snapshot_tomar(v_negocio_id, 'ejecucion', p_ejecucion_id);
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO fallas (workflow, ejecucion_id, sesion_id, tipo, transitoria, detalle)
            VALUES ('snapshot_tomar', p_ejecucion_id, v_sesion_id, 'permanente', false,
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
                              'snapshot_id', v_snapshot);
END;
$$;

-- =============================================================================
-- 6. Backfill desde ejecuciones.hallazgos (C4)
-- =============================================================================
-- Material viejo para que un negocio con historia no arranque la Fase B en
-- blanco. Es NECESARIAMENTE PARCIAL y se marca como tal: de los hallazgos solo
-- se puede recuperar lo que el informe necesitaba —salud, periodo, resumen,
-- pareto y los productos que dispararon regla—, nunca el catálogo completo.
--
-- Por eso `metricas.parcial = true` y la lista de lo que falta: una regla
-- comparativa de B3 que necesite el margen de TODOS los productos tiene que
-- poder saltarse estos snapshots en vez de concluir que un producto ausente
-- "dejó de venderse" cuando lo único que pasa es que nunca estuvo.
--
-- Nunca pisa un snapshot real: el ON CONFLICT descarta si ya hay uno de ese día.
CREATE OR REPLACE FUNCTION snapshots_backfill()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
    v_n int := 0;
    r   record;
BEGIN
    FOR r IN
        -- Una ejecución por negocio y día: la última completada de cada día.
        SELECT DISTINCT ON (e.negocio_id, e.inicio::date)
               e.id, e.negocio_id, e.inicio::date AS fecha, e.hallazgos AS h
        FROM ejecuciones e
        JOIN servicios s ON s.codigo = e.servicio_codigo AND s.entrada = 'archivos'
        WHERE e.estado = 'completada'
          AND jsonb_typeof(e.hallazgos) = 'object'
          AND e.hallazgos ? 'periodo'
        ORDER BY e.negocio_id, e.inicio::date, e.id DESC
    LOOP
        INSERT INTO snapshots_negocio (negocio_id, fecha, version, periodo, salud,
                                       metricas, origen, ejecucion_id)
        SELECT r.negocio_id, r.fecha, snapshot_version(),
               CASE WHEN (r.h #>> '{periodo,desde}') IS NOT NULL
                    THEN daterange((r.h #>> '{periodo,desde}')::date,
                                   (r.h #>> '{periodo,hasta}')::date, '[]') END,
               r.h -> 'salud',
               jsonb_build_object(
                 'parcial', true,
                 'reconstruido_de', 'ejecuciones.hallazgos',
                 -- Lo que NO se puede reconstruir, dicho explícitamente para que
                 -- B3 no lo confunda con "estaba en cero". `totales` figura
                 -- porque solo se recuperan los conteos de movimientos: los
                 -- importes y `base_mes` nunca estuvieron en los hallazgos.
                 'faltan', jsonb_build_array('totales.ventas', 'totales.compras',
                                             'totales.base_mes', 'margenes',
                                             'coberturas', 'proveedores',
                                             'precios_proveedor', 'ventas_producto',
                                             'pareto', 'calidad', 'umbrales'),
                 -- Lo que sí se recupera se escribe con LA FORMA DEL CONTRATO,
                 -- no con la que tenía en los hallazgos. Un snapshot parcial es
                 -- un snapshot con huecos, no un snapshot con otro esquema: si
                 -- no, B3 tendría que saber leer las dos formas.
                 'totales', jsonb_build_object(
                    'movimientos_venta',  r.h #> '{periodo,movimientos_venta}',
                    'movimientos_compra', r.h #> '{periodo,movimientos_compra}'),
                 'productos', jsonb_build_object(
                    'total',               r.h #> '{resumen,productos}',
                    'con_precio',          r.h #> '{resumen,con_precio}',
                    'margen_promedio_pct', r.h #> '{resumen,margen_promedio_pct}'),
                 -- Estos NO se pueden llevar al contrato: los hallazgos guardan
                 -- el nombre del producto y no su id, así que no son emparejables
                 -- con los de un snapshot real. Van con nombre propio para que
                 -- nadie los confunda con las claves de v1.
                 'pareto_parcial',         coalesce(r.h -> 'pareto', '[]'::jsonb),
                 'margen_bajo_parcial',    coalesce(r.h -> 'margen_bajo', '[]'::jsonb),
                 'derivas_parcial',        coalesce(r.h -> 'deriva_costo', '[]'::jsonb),
                 'baja_cobertura_parcial', coalesce(r.h -> 'baja_cobertura', '[]'::jsonb)),
               'backfill', r.id
        ON CONFLICT ON CONSTRAINT uq_snapshot_dia DO NOTHING;

        v_n := v_n + (CASE WHEN FOUND THEN 1 ELSE 0 END);
    END LOOP;

    RETURN v_n;
END;
$$;

SELECT snapshots_backfill() AS snapshots_reconstruidos;

-- =============================================================================
-- 7. El portal ve la historia
-- =============================================================================
-- La pestaña Informes era la más esbozada del portal y es el destino natural
-- del histórico. Acá va solo la lista: el comparativo es B3.
CREATE OR REPLACE FUNCTION portal_snapshots(p_limite int DEFAULT 24)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    RETURN coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'fecha', fecha,
               'periodo_desde', lower(periodo), 'periodo_hasta', upper(periodo),
               'origen', origen,
               'parcial', coalesce((metricas -> 'parcial')::boolean, false),
               'salud', salud,
               'ventas',  metricas #> '{totales,ventas}',
               'compras', metricas #> '{totales,compras}',
               'productos', metricas #> '{productos,total}',
               'margen_promedio_pct', metricas #> '{productos,margen_promedio_pct}')
               ORDER BY fecha DESC)
      FROM (SELECT * FROM snapshots_negocio
             WHERE negocio_id = v_negocio
             ORDER BY fecha DESC LIMIT p_limite) s), '[]'::jsonb);
END;
$$;

GRANT EXECUTE ON FUNCTION portal_snapshots(int) TO portal_usuario;

NOTIFY pgrst, 'reload schema';
