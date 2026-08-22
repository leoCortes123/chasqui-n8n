-- 061_perfil_negocio.sql — todo lo que Chasqui sabe de un negocio, en un objeto.
--
-- El dato ya existe casi todo: está repartido en siete vistas de cálculo, dos
-- tablas de memoria (`snapshots_negocio`, `recomendaciones`) y `movimientos`.
-- Lo que falta es la consolidación, y falta porque las dos fases que vienen la
-- necesitan como entrada única:
--
--   * **Fase C** ("preguntar a los números"). La arquitectura obligatoria es
--     `intención → agregado determinístico → contexto estructurado → LLM`. Ese
--     "contexto estructurado" es esto. Sin un objeto consolidado, cada intención
--     tendría que rearmarlo, y ahí es donde se cuela lógica de cálculo en un
--     prompt — justo lo que R-I prohíbe.
--   * **El portal**, que hoy pide seis RPC distintas para pintar una pantalla.
--
-- QUÉ ES UN PERFIL, Y QUÉ NO ES
--
-- Un perfil es lo ESTABLE de un negocio: qué vende, a quién le compra, cuánto
-- margen suele dejar, en qué meses vende más, qué problemas le vuelven. No es
-- un informe ni un diagnóstico; no dice qué hacer. Es el material sobre el que
-- otros deciden.
--
-- Por eso incluye la estacionalidad y los problemas RECURRENTES —dos cosas que
-- solo se ven con historia— y no incluye las recomendaciones vigentes de hoy,
-- que ya tienen su propio accesor (`recomendaciones_vigentes`, 059).
--
-- POR QUÉ VISTA Y ADEMÁS FUNCIÓN
--
-- La vista es para mirar y cruzar: `SELECT * FROM v_perfil_negocio WHERE ...`
-- sirve para operar y para el admin. La función empaqueta la fila en el jsonb
-- que van a consumir C1 y el portal, que necesitan un objeto, no una fila. La
-- función no recalcula nada: lee la vista.

-- =============================================================================
-- 1. La vista
-- =============================================================================
-- Cada bloque es una subconsulta correlacionada por `negocio_id`: filtrando por
-- un negocio, Postgres empuja el filtro y no consolida los demás.
CREATE OR REPLACE VIEW v_perfil_negocio AS
SELECT
  n.id AS negocio_id,
  n.nombre,
  n.plan,
  n.tipo AS tipo_codigo,
  (SELECT nombre FROM tipos_negocio WHERE codigo = n.tipo) AS tipo_nombre,
  (nullif(btrim(coalesce(n.nit, '')), '') IS NOT NULL) AS tiene_nit,

  -- --- Qué ventana de datos cubre ------------------------------------------
  (SELECT jsonb_build_object(
     'desde', min(fecha), 'hasta', max(fecha),
     'meses', round(greatest((max(fecha) - min(fecha))::numeric / 30.0, 0), 1),
     'movimientos', count(*),
     'ventas',  round(coalesce(sum(valor_total) FILTER (WHERE tipo = 'venta'), 0)),
     'compras', round(coalesce(sum(valor_total) FILTER (WHERE tipo = 'compra'), 0)))
   FROM mov_visibles WHERE negocio_id = n.id) AS periodo,

  -- --- Qué vende -----------------------------------------------------------
  -- El margen TÍPICO es la mediana, no el promedio: un solo producto con margen
  -- absurdo —o con el precio mal cargado— corre el promedio y no la mediana, y
  -- de estos datos se fía la Fase C para contestar preguntas.
  (SELECT jsonb_build_object(
     'total', count(*),
     'con_precio', count(*) FILTER (WHERE precio_actual IS NOT NULL),
     'margen_mediano_pct', round(percentile_cont(0.5)
                                 WITHIN GROUP (ORDER BY margen_pct)::numeric, 2),
     'margen_min_pct', round(min(margen_pct), 2),
     'margen_max_pct', round(max(margen_pct), 2))
   FROM v_margen_producto WHERE negocio_id = n.id) AS productos,

  -- Los que concentran la utilidad. Es la respuesta a "¿cuál es mi producto más
  -- rentable?", una de las ocho preguntas de la definición de producto.
  (SELECT coalesce(jsonb_agg(jsonb_build_object(
            'producto_id', pa.producto_id, 'nombre', p.nombre_canonico,
            'utilidad', round(pa.utilidad), 'pct_utilidad', pa.pct_utilidad)
            ORDER BY pa.utilidad DESC), '[]'::jsonb)
   FROM v_pareto_utilidad pa JOIN productos p ON p.id = pa.producto_id
   WHERE pa.negocio_id = n.id AND pa.pct_acumulado <= 80) AS top_productos,

  -- --- A quién le compra ---------------------------------------------------
  (SELECT jsonb_build_object(
     'total', count(*),
     'principal', (array_agg(prov ORDER BY gasto DESC))[1],
     'concentracion_pct', round(max(gasto) * 100.0 / nullif(sum(gasto), 0), 1),
     'detalle', coalesce(jsonb_agg(jsonb_build_object(
                  'proveedor', prov, 'gasto', round(gasto))
                  ORDER BY gasto DESC), '[]'::jsonb))
   FROM (SELECT nullif(btrim(coalesce(raw ->> 'proveedor', '')), '') AS prov,
                sum(valor_total) AS gasto
         FROM mov_visibles
         WHERE negocio_id = n.id AND tipo = 'compra'
           AND nullif(btrim(coalesce(raw ->> 'proveedor', '')), '') IS NOT NULL
         GROUP BY 1) g) AS proveedores,

  -- --- Cuándo vende --------------------------------------------------------
  -- Ventas por mes del calendario, sobre toda la historia visible. `suficiente`
  -- dice si hay al menos un año: sin eso, "en diciembre vendés más" no es
  -- estacionalidad, es que diciembre fue el único diciembre.
  (SELECT jsonb_build_object(
     'suficiente', (max(fecha) - min(fecha)) >= 365,
     'por_mes', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
                 'mes', m, 'ventas', round(v), 'meses_observados', obs)
                 ORDER BY m)
        FROM (SELECT extract(month FROM fecha)::int AS m,
                     sum(valor_total) AS v,
                     count(DISTINCT date_trunc('month', fecha)) AS obs
              FROM mov_visibles
              WHERE negocio_id = n.id AND tipo = 'venta' AND fecha IS NOT NULL
              GROUP BY 1) s), '[]'::jsonb))
   FROM mov_visibles WHERE negocio_id = n.id AND fecha IS NOT NULL) AS estacionalidad,

  -- --- Qué problemas le vuelven --------------------------------------------
  -- Esto no existía antes de B2 y es la mitad del valor del perfil: no es lo
  -- mismo un negocio al que le avisaron una vez de un margen bajo que uno al
  -- que se lo vienen diciendo desde hace seis meses.
  (SELECT coalesce(jsonb_agg(jsonb_build_object(
            'regla', regla, 'veces', veces, 'abiertas', abiertas,
            'resueltas', resueltas, 'primera_vez', primera)
            ORDER BY veces DESC), '[]'::jsonb)
   FROM (SELECT regla, count(*) AS veces,
                count(*) FILTER (WHERE estado IN ('nueva','vigente')) AS abiertas,
                count(*) FILTER (WHERE estado = 'resuelta')           AS resueltas,
                min(detectada_en)::date AS primera
         FROM recomendaciones WHERE negocio_id = n.id
         GROUP BY 1) r) AS problemas_recurrentes,

  -- --- Qué se hizo al respecto ---------------------------------------------
  -- `por_accion` va a ser 0 hasta que exista D1, y está bien que se vea: es la
  -- medida de si el ciclo detectar→ejecutar está cerrado o no.
  (SELECT jsonb_build_object(
     'cerradas_total', count(*) FILTER (WHERE estado NOT IN ('nueva','vigente')),
     'por_dato',       count(*) FILTER (WHERE cerrada_por = 'dato'),
     'por_accion',     count(*) FILTER (WHERE cerrada_por = 'accion_usuario'),
     'ignoradas',      count(*) FILTER (WHERE estado = 'ignorada'),
     'sin_datos',      count(*) FILTER (WHERE cerrada_por = 'sin_datos'))
   FROM recomendaciones WHERE negocio_id = n.id) AS acciones,

  -- --- Cómo viene la salud -------------------------------------------------
  (SELECT jsonb_build_object(
     'snapshots', count(*),
     'ultimo', max(fecha),
     'serie', coalesce((SELECT jsonb_agg(jsonb_build_object(
                          'fecha', fecha, 'indice', salud -> 'indice') ORDER BY fecha)
                        FROM (SELECT fecha, salud FROM snapshots_negocio
                              WHERE negocio_id = n.id ORDER BY fecha DESC LIMIT 12) u),
                       '[]'::jsonb))
   FROM snapshots_negocio WHERE negocio_id = n.id) AS salud_historia,

  -- --- Qué tan confiable es todo lo de arriba ------------------------------
  -- Va en el perfil y no en una nota al pie porque la Fase C va a responder
  -- preguntas con estos números, y una respuesta calculada sobre datos con
  -- agujeros tiene que poder decirlo.
  (SELECT jsonb_build_object(
     'movs_sin_producto', movs_sin_producto,
     'dinero_sin_producto', dinero_sin_producto,
     'pct_dinero_fuera', coalesce(pct_dinero_fuera, 0),
     'productos_stock_estimado', (SELECT count(*) FROM v_balance_unidades
                                  WHERE negocio_id = n.id AND origen_stock = 'estimado'))
   FROM v_calidad_matching WHERE negocio_id = n.id) AS calidad

FROM negocios n;

COMMENT ON VIEW v_perfil_negocio IS
  'Lo estable de un negocio: qué vende, a quién le compra, qué margen suele '
  'dejar, cuándo vende más, qué problemas le vuelven y qué se hizo. Es el '
  'contexto estructurado que consume la Fase C — no un informe ni un '
  'diagnóstico: no dice qué hacer.';

-- =============================================================================
-- 2. El mismo perfil, empaquetado
-- =============================================================================
-- No recalcula nada: lee la vista y arma el objeto. Es la forma en que lo van a
-- pedir C1 y el portal.
CREATE OR REPLACE FUNCTION perfil_negocio(p_negocio_id bigint)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
      'negocio_id', negocio_id,
      'nombre', nombre,
      'plan', plan,
      'tipo', tipo_nombre,
      'tiene_nit', tiene_nit,
      'periodo', periodo,
      'productos', productos,
      'top_productos', top_productos,
      'proveedores', proveedores,
      'estacionalidad', estacionalidad,
      'problemas_recurrentes', problemas_recurrentes,
      'acciones', acciones,
      'salud_historia', salud_historia,
      'calidad', calidad)
    FROM v_perfil_negocio WHERE negocio_id = p_negocio_id;
$$;

COMMENT ON FUNCTION perfil_negocio(bigint) IS
  'v_perfil_negocio empaquetada en un objeto. La entrada de C1.';

-- =============================================================================
-- 3. El portal
-- =============================================================================
-- La pestaña "Mi negocio" mostraba el NIT y poco más. Ahora puede mostrar lo
-- que Chasqui sabe del negocio, que es también la mejor forma de que el dueño
-- detecte que algo está mal cargado.
CREATE OR REPLACE FUNCTION portal_perfil()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
BEGIN
    RETURN perfil_negocio(portal_negocio());
END;
$$;

GRANT EXECUTE ON FUNCTION portal_perfil() TO portal_usuario;

NOTIFY pgrst, 'reload schema';
