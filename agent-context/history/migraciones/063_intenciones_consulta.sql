-- 063_intenciones_consulta.sql — preguntar por un número puntual y que el número
-- exista antes de preguntar.
--
-- C1 le dio al modelo un contexto rico y lo dejó elegir qué usar. Eso alcanza
-- para las preguntas abiertas —"¿cómo voy?", "¿qué hago primero?"— y NO alcanza
-- para las puntuales: "¿cuánto vendí en marzo?" no se puede responder con un
-- perfil, y el prompt tiene prohibido calcular. Hoy contesta qué dato sí tiene,
-- que es honesto pero pobre.
--
-- LO QUE `intenciones` ES, Y LO QUE NO
--
-- NO es un despachador de funciones. Si cada intención fuera "llamá a esta
-- función", agregar una pregunta nueva sería escribir código, y volveríamos al
-- problema que el proyecto entero viene evitando: comportamiento en funciones en
-- vez de en filas.
--
-- Es un CONTRATO DE DATOS. Cada fila declara qué se pide y sobre qué ventana;
-- un único agregador genérico produce el resultado. Una intención nueva es un
-- INSERT — mismo patrón que `servicios.funcion_hallazgos` y que `plantillas`.
--
-- POR QUÉ LA DETECCIÓN ES DETERMINÍSTICA Y NO UNA LLAMADA AL MODELO
--
-- Se podría pedirle al LLM que clasifique la intención. No se hace, por tres
-- razones: cuesta una llamada más antes de la que ya se hace; introduce una
-- fuente de variabilidad en un camino donde hoy no hay ninguna; y sobre todo,
-- un patrón que falla se arregla con un UPDATE a un array, mientras que un
-- clasificador que falla se arregla peleando con un prompt. Si algún día los
-- patrones no dan, el modelo puede entrar SOLO como desempate — nunca como el
-- que decide qué se calcula.
--
-- Cuando ninguna intención coincide, no pasa nada malo: queda el contexto
-- abierto de C1, que ya responde bastante.
--
-- LAS OCHO PREGUNTAS
--
-- El roadmap las declara prueba de aceptación de esta fase pero no las enumera
-- en ninguna parte. Se derivaron de lo que el producto ya promete —el texto de
-- ayuda del módulo y la introducción de la guía funcional— y quedan escritas
-- acá para que la próxima fase discuta sobre algo concreto:
--
--   1. ¿Cómo está mi negocio?                    (C1: salud + comparativo)
--   2. ¿Qué debería hacer primero?               (C1: recomendaciones)
--   3. ¿Cuál es mi producto más rentable?        → intención `utilidad`
--   4. ¿Qué producto me deja poco margen?        → intención `margen`
--   5. ¿A qué producto le subió el costo?        → intención `costo`
--   6. ¿Qué se me está quedando quieto?          → intención `cobertura`
--   7. ¿Cuánto vendí en <periodo>?               → intención `ventas`
--   8. ¿Cuánto le compré a <proveedor>?          → intención `compras`
--
-- Queda fuera "¿quién me debe?": la cartera solo se llena desde XML DIAN y su
-- reconversión es la Fase F.

-- =============================================================================
-- 1. El contrato
-- =============================================================================
CREATE TABLE IF NOT EXISTS intenciones (
    codigo      text PRIMARY KEY,
    nombre      text NOT NULL,
    -- Lo que dispara la intención. Se busca cada patrón dentro del texto
    -- normalizado de la pregunta: sin tildes, en minúsculas.
    patrones    text[] NOT NULL,
    -- Qué se pide. El agregador sabe calcular estas y solo estas.
    metrica     text NOT NULL
                CHECK (metrica IN ('ventas','compras','margen','costo',
                                   'cobertura','utilidad','gasto_proveedor')),
    -- Ventana por defecto si la pregunta no dice una.
    periodo     text NOT NULL DEFAULT 'todo'
                CHECK (periodo IN ('todo','mes_actual','mes_anterior',
                                   'ano_actual','ultimos_30')),
    -- Qué dimensiones tiene sentido buscar en el texto para esta intención.
    filtros     text[] NOT NULL DEFAULT '{}',
    -- Contra qué se compara. NULL = no aplica.
    comparativo text CHECK (comparativo IN ('periodo_anterior','mismo_mes_ano_pasado')),
    orden       int NOT NULL DEFAULT 100,
    activo      boolean NOT NULL DEFAULT true
);

COMMENT ON TABLE intenciones IS
  'Contrato de datos, no despachador de funciones: cada fila declara QUÉ se '
  'pide y sobre qué ventana, y un agregador genérico lo calcula. Una pregunta '
  'nueva que el sistema pueda responder es un INSERT.';

INSERT INTO intenciones (codigo, nombre, patrones, metrica, periodo, filtros, comparativo, orden) VALUES
('ventas', 'Cuánto vendí',
 ARRAY['cuanto vendi','cuanto he vendido','cuanto vendimos','mis ventas',
       'las ventas','cuanto facture','cuanto factura','total de ventas','vendi en'],
 'ventas', 'mes_anterior', ARRAY['producto'], 'mismo_mes_ano_pasado', 10),

('compras', 'Cuánto compré',
 ARRAY['cuanto compre','cuanto he comprado','cuanto gaste','mis compras',
       'las compras','cuanto le compre','total de compras','gasto en compras'],
 'compras', 'mes_anterior', ARRAY['producto','proveedor'], 'mismo_mes_ano_pasado', 20),

('gasto_proveedor', 'Cuánto le compro a cada proveedor',
 ARRAY['a que proveedor','cual proveedor','mis proveedores','por proveedor',
       'a quien le compro','le compro mas'],
 'gasto_proveedor', 'todo', ARRAY['proveedor'], NULL, 30),

('utilidad', 'Qué producto me deja más plata',
 ARRAY['mas rentable','deja mas plata','deja mas ganancia','mas ganancia',
       'que me deja mas','producto estrella','mas utilidad','me da mas plata'],
 'utilidad', 'todo', ARRAY['producto'], NULL, 40),

('margen', 'Qué producto me deja poco',
 ARRAY['poco margen','margen bajo','me deja poco','pierdo plata','no me deja',
       'mi margen','que margen','margen de','poca ganancia'],
 'margen', 'todo', ARRAY['producto'], NULL, 50),

('costo', 'A qué le subió el costo',
 ARRAY['subio el costo','subio el precio','me subieron','esta mas caro',
       'aumento el costo','subio de precio','que se encarecio'],
 'costo', 'todo', ARRAY['producto','proveedor'], NULL, 60),

('cobertura', 'Qué se me agota y qué está quieto',
 -- 'quieto'/'quieta' sueltos y no 'esta quieto': el dueño escribe "se me está
 -- quedando quieto", no la forma canónica. Los patrones se calibran contra
 -- preguntas reales, y por eso son una columna y no código.
 ARRAY['se me acaba','se agota','me queda','cuanto stock','cuanto inventario',
       'quieto','quieta','no se vende','no rota','cuanto tengo de','me alcanza'],
 'cobertura', 'todo', ARRAY['producto'], NULL, 70)
ON CONFLICT (codigo) DO UPDATE
  SET nombre = EXCLUDED.nombre, patrones = EXCLUDED.patrones,
      metrica = EXCLUDED.metrica, periodo = EXCLUDED.periodo,
      filtros = EXCLUDED.filtros, comparativo = EXCLUDED.comparativo,
      orden = EXCLUDED.orden, activo = true;

-- =============================================================================
-- 2. Detectar la intención
-- =============================================================================
-- Gana la que más patrones distintos matchea; a igualdad, la de menor `orden`.
-- Devuelve NULL si ninguna coincide, y eso NO es un error: significa "seguí con
-- el contexto abierto de C1", que ya responde bastante.
CREATE OR REPLACE FUNCTION intencion_detectar(p_texto text)
RETURNS text LANGUAGE sql STABLE AS $$
    WITH q AS (SELECT norm_texto(coalesce(p_texto, '')) AS t)
    SELECT i.codigo
    FROM intenciones i, q,
         LATERAL (SELECT count(*) AS n FROM unnest(i.patrones) pa
                   WHERE q.t LIKE '%' || norm_texto(pa) || '%') m
    WHERE i.activo AND m.n > 0
    ORDER BY m.n DESC, i.orden
    LIMIT 1;
$$;

-- =============================================================================
-- 3. Resolver el periodo a fechas concretas
-- =============================================================================
-- El texto manda sobre el defecto de la intención: si el dueño dice "en marzo",
-- se usa marzo aunque la intención traiga `mes_anterior`.
--
-- El ancla es `p_hasta` —la fecha más reciente de los datos— y no el reloj, por
-- la misma razón que en B3: un negocio que subió en agosto un archivo que
-- termina en mayo preguntó por SUS datos, no por el calendario.
CREATE OR REPLACE FUNCTION periodo_resolver(p_texto text, p_defecto text,
                                            p_hasta date)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
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
$$;

-- =============================================================================
-- 4. El agregador genérico
-- =============================================================================
-- UNA función para las siete métricas. Es lo que evita que `intenciones` se
-- convierta en un despachador: las métricas se diferencian en QUÉ suman, no en
-- la forma del resultado, así que comparten estructura y el contrato es estable.
--
-- Todo sale de `mov_visibles` y de las vistas de cálculo: ni una cifra de acá
-- pasa por el modelo antes de estar calculada (R-I).
CREATE OR REPLACE FUNCTION intencion_agregados(p_negocio_id bigint,
                                               p_metrica    text,
                                               p_desde      date,
                                               p_hasta      date,
                                               p_producto   bigint DEFAULT NULL,
                                               p_proveedor  text   DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_tipo tipo_movimiento;
    v_out  jsonb;
BEGIN
    IF p_metrica IN ('ventas','compras') THEN
        v_tipo := CASE p_metrica WHEN 'ventas' THEN 'venta' ELSE 'compra' END::tipo_movimiento;

        SELECT jsonb_build_object(
                 'total', round(coalesce(sum(valor_total), 0)),
                 -- La misma cifra ya escrita como se escribe en Colombia. Sin
                 -- esto el modelo entrega "68400" y queda a que se le ocurra
                 -- formatearlo — y si lo formatea por su cuenta, es una cifra
                 -- que no está en el contexto y `validar_cifras` la rechaza.
                 'total_txt', '$' || miles(round(coalesce(sum(valor_total), 0))),
                 'movimientos', count(*),
                 'unidades', round(coalesce(sum(cantidad), 0), 2),
                 'por_mes', coalesce((
                    SELECT jsonb_agg(jsonb_build_object(
                             'mes', to_char(mes, 'YYYY-MM'), 'total', round(t))
                             ORDER BY mes)
                    FROM (SELECT date_trunc('month', m.fecha) AS mes, sum(m.valor_total) AS t
                          FROM mov_visibles m
                          WHERE m.negocio_id = p_negocio_id AND m.tipo = v_tipo
                            AND (p_desde IS NULL OR m.fecha >= p_desde)
                            AND (p_hasta IS NULL OR m.fecha <= p_hasta)
                            AND (p_producto IS NULL OR m.producto_id = p_producto)
                            AND (p_proveedor IS NULL
                                 OR btrim(coalesce(m.raw ->> 'proveedor','')) = p_proveedor)
                          GROUP BY 1) s), '[]'::jsonb),
                 'top_productos', coalesce((
                    SELECT jsonb_agg(jsonb_build_object(
                             'producto', nom, 'total', round(t),
                             'total_txt', '$' || miles(round(t)),
                             'unidades', round(u, 2))
                             ORDER BY t DESC)
                    FROM (SELECT p.nombre_canonico AS nom, sum(m.valor_total) AS t,
                                 sum(m.cantidad) AS u
                          FROM mov_visibles m JOIN productos p ON p.id = m.producto_id
                          WHERE m.negocio_id = p_negocio_id AND m.tipo = v_tipo
                            AND (p_desde IS NULL OR m.fecha >= p_desde)
                            AND (p_hasta IS NULL OR m.fecha <= p_hasta)
                            AND (p_producto IS NULL OR m.producto_id = p_producto)
                            AND (p_proveedor IS NULL
                                 OR btrim(coalesce(m.raw ->> 'proveedor','')) = p_proveedor)
                          GROUP BY 1 ORDER BY 2 DESC LIMIT 8) s), '[]'::jsonb))
          INTO v_out
        FROM mov_visibles m
        WHERE m.negocio_id = p_negocio_id AND m.tipo = v_tipo
          AND (p_desde IS NULL OR m.fecha >= p_desde)
          AND (p_hasta IS NULL OR m.fecha <= p_hasta)
          AND (p_producto IS NULL OR m.producto_id = p_producto)
          AND (p_proveedor IS NULL
               OR btrim(coalesce(m.raw ->> 'proveedor','')) = p_proveedor);

    ELSIF p_metrica = 'gasto_proveedor' THEN
        SELECT jsonb_build_object(
                 'total', round(coalesce(sum(gasto), 0)),
                 'total_txt', '$' || miles(round(coalesce(sum(gasto), 0))),
                 'proveedores', coalesce(jsonb_agg(jsonb_build_object(
                    'proveedor', prov, 'gasto', round(gasto),
                    'gasto_txt', '$' || miles(round(gasto)),
                    'pct', round(gasto * 100.0 / nullif(sum(gasto) OVER (), 0), 1))
                    ORDER BY gasto DESC), '[]'::jsonb))
          INTO v_out
        FROM (SELECT nullif(btrim(coalesce(raw ->> 'proveedor','')),'') AS prov,
                     sum(valor_total) AS gasto
              FROM mov_visibles
              WHERE negocio_id = p_negocio_id AND tipo = 'compra'
                AND (p_desde IS NULL OR fecha >= p_desde)
                AND (p_hasta IS NULL OR fecha <= p_hasta)
                AND nullif(btrim(coalesce(raw ->> 'proveedor','')),'') IS NOT NULL
              GROUP BY 1) g;

    ELSIF p_metrica = 'margen' THEN
        -- Sin ventana: el margen es del estado actual, no de un periodo. Se
        -- ordena de peor a mejor porque la pregunta casi siempre es "¿cuál me
        -- deja poco?", no "¿cuál me deja bien?".
        SELECT jsonb_build_object(
                 'margen_mediano_pct', round(percentile_cont(0.5)
                     WITHIN GROUP (ORDER BY margen_pct)::numeric, 2),
                 'productos', coalesce(jsonb_agg(jsonb_build_object(
                    'producto', nombre_canonico, 'costo', costo_actual,
                    'precio', precio_actual, 'margen_pct', margen_pct)
                    ORDER BY margen_pct), '[]'::jsonb))
          INTO v_out
        FROM v_margen_producto
        WHERE negocio_id = p_negocio_id AND margen_pct IS NOT NULL
          AND (p_producto IS NULL OR producto_id = p_producto);

    ELSIF p_metrica = 'costo' THEN
        SELECT jsonb_build_object(
                 'productos', coalesce(jsonb_agg(jsonb_build_object(
                    'producto', p.nombre_canonico, 'costo_ini', d.costo_ini,
                    'costo_fin', d.costo_fin, 'deriva_pct', d.deriva_pct)
                    ORDER BY d.deriva_pct DESC), '[]'::jsonb))
          INTO v_out
        FROM v_deriva_costo d JOIN productos p ON p.id = d.producto_id
        WHERE d.negocio_id = p_negocio_id
          AND (p_producto IS NULL OR d.producto_id = p_producto);

    ELSIF p_metrica = 'cobertura' THEN
        SELECT jsonb_build_object(
                 'productos', coalesce(jsonb_agg(jsonb_build_object(
                    'producto', p.nombre_canonico,
                    'dias_cobertura', r.dias_cobertura,
                    'unidades_por_dia', r.unidades_por_dia,
                    'stock', b.balance,
                    -- 054: el origen del stock viaja siempre. Responder "te
                    -- quedan 40" sobre una estimación sin decirlo sería
                    -- exactamente lo que A2 vino a arreglar.
                    'origen_stock', r.origen_stock)
                    ORDER BY r.dias_cobertura), '[]'::jsonb))
          INTO v_out
        FROM v_rotacion_producto r
        JOIN productos p ON p.id = r.producto_id
        LEFT JOIN v_balance_unidades b
               ON b.producto_id = r.producto_id AND b.negocio_id = r.negocio_id
        WHERE r.negocio_id = p_negocio_id
          AND (p_producto IS NULL OR r.producto_id = p_producto);

    ELSIF p_metrica = 'utilidad' THEN
        SELECT jsonb_build_object(
                 'productos', coalesce(jsonb_agg(jsonb_build_object(
                    'producto', p.nombre_canonico, 'utilidad', round(pa.utilidad),
                    'utilidad_txt', '$' || miles(round(pa.utilidad)),
                    'pct_utilidad', pa.pct_utilidad,
                    'pct_acumulado', pa.pct_acumulado)
                    ORDER BY pa.utilidad DESC), '[]'::jsonb))
          INTO v_out
        FROM v_pareto_utilidad pa JOIN productos p ON p.id = pa.producto_id
        WHERE pa.negocio_id = p_negocio_id
          AND (p_producto IS NULL OR pa.producto_id = p_producto);
    END IF;

    RETURN coalesce(v_out, '{}'::jsonb);
END;
$$;

-- =============================================================================
-- 5. La intención resuelta, de punta a punta
-- =============================================================================
-- El objeto que consume el prompt: qué se pidió, sobre qué ventana, con qué
-- filtros, contra qué se compara y —lo importante— **el resultado ya calculado**.
CREATE OR REPLACE FUNCTION intencion_resolver(p_negocio_id bigint, p_texto text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
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
$$;

-- =============================================================================
-- 6. El contexto de `consulta` incorpora la intención
-- =============================================================================
-- Se agrega un bloque `consulta`, no se reemplaza nada: cuando ninguna intención
-- coincide queda NULL y el modelo trabaja con el contexto abierto de C1, que es
-- exactamente el comportamiento anterior.
CREATE OR REPLACE FUNCTION contexto_negocio_recuperar(p_negocio_id bigint,
                                                      p_contexto jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_pregunta text := btrim(coalesce(p_contexto ->> 'pregunta', ''));
    v_perfil   jsonb := perfil_negocio(p_negocio_id);
    v_hechos   jsonb := conocimiento_buscar(p_negocio_id, v_pregunta);
BEGIN
    RETURN jsonb_build_object(
        'negocio_id', p_negocio_id,
        'generado_en', now(),
        'pregunta', v_pregunta,

        -- La KB, tal cual. No se toca: cuando la pregunta es por un precio o
        -- por el horario, lo que alguien escribió a mano le gana a cualquier
        -- agregado.
        'hechos', coalesce(v_hechos, '[]'::jsonb),

        -- >>> 063: si la pregunta pide un número puntual, acá está calculado.
        -- NULL cuando ninguna intención coincide.
        'consulta', intencion_resolver(p_negocio_id, v_pregunta),

        -- >>> 062: los números, que es lo que faltaba.
        'negocio', jsonb_build_object(
            'tipo',            v_perfil -> 'tipo',
            'periodo',         v_perfil -> 'periodo',
            'productos',       v_perfil -> 'productos',
            'top_productos',   v_perfil -> 'top_productos',
            'proveedores',     v_perfil -> 'proveedores',
            'estacionalidad',  v_perfil -> 'estacionalidad',
            'problemas_recurrentes', v_perfil -> 'problemas_recurrentes',
            'acciones',        v_perfil -> 'acciones',
            'calidad',         v_perfil -> 'calidad'),

        'estado', salud_negocio(p_negocio_id),
        'comparativo', hallazgos_comparativo(p_negocio_id),
        'recomendaciones', recomendaciones_vigentes(p_negocio_id, 8),

        'encabezado', jsonb_build_object(
            'titulo', 'Tu pregunta',
            'subtitulo', v_pregunta,
            'metricas', '[]'::jsonb));
END;
$$;

-- El prompt aprende que hay un bloque con la respuesta ya calculada, y que ese
-- bloque manda. Sigue sin recibir una sola regla de cálculo.
UPDATE prompts SET sistema = replace(sistema,
'EL CONTEXTO trae estos bloques, y no todos sirven para toda pregunta:

- "hechos"',
'EL CONTEXTO trae estos bloques, y no todos sirven para toda pregunta:

- "consulta": si está, es la respuesta a lo que preguntaron, YA CALCULADA. "periodo.etiqueta" dice sobre qué ventana, "agregados" trae las cifras y "comparativo" contra qué se compara. Cuando este bloque está, la respuesta sale de acá y el resto es contexto de apoyo. Si "filtros" nombra un producto o un proveedor, decilo en la respuesta para que el dueño sepa qué entendiste.
- "hechos"')
WHERE servicio_codigo = 'consulta' AND activo;

NOTIFY pgrst, 'reload schema';
