-- Verificación de los escenarios generados por bin/gen_datos_prueba.py.
--
-- A diferencia de los otros tres bancos, este NO arma su propio fixture: lee
-- los negocios 'PRUEBA GEN %' que dejó bin/cargar_datos_prueba.py y comprueba
-- que Chasqui vea en ellos exactamente lo que el manifest declara. Un escenario
-- que no esté cargado sale como WARN y no como falla: el perfil `small` carga
-- tres de los doce a propósito.
--
-- Corre entera dentro de una transacción que se descarta.
--
--   set -a; . ./.env; set +a
--   docker compose exec -T -e PGPASSWORD="$CHASQUI_DB_PASSWORD" postgres \
--     psql -U "$CHASQUI_DB_USER" -d "$CHASQUI_DB" < db/pruebas/escenarios_generados.sql
--
-- Las expectativas están escritas acá y no leídas del manifest a propósito: son
-- el contrato del dataset, y si el generador cambia lo que produce, esta lista
-- tiene que cambiar con un commit y no en silencio.
\set ON_ERROR_STOP on
\pset format aligned
BEGIN;

CREATE TEMP TABLE r(prueba text, esperado text, obtenido text, ok boolean,
                    nivel text DEFAULT 'PASS');
CREATE FUNCTION _chk(p text, esp text, obt text) RETURNS void LANGUAGE sql AS $$
    INSERT INTO r(prueba, esperado, obtenido, ok, nivel)
    VALUES (p, esp, obt, esp IS NOT DISTINCT FROM obt,
            CASE WHEN esp IS NOT DISTINCT FROM obt THEN 'PASS' ELSE 'FAIL' END);
$$;
CREATE FUNCTION _warn(p text, obt text) RETURNS void LANGUAGE sql AS $$
    INSERT INTO r(prueba, esperado, obtenido, ok, nivel)
    VALUES (p, '(no evaluable)', obt, true, 'WARN');
$$;

-- ===========================================================================
-- Los negocios generados y lo que cada escenario declara
-- ===========================================================================
CREATE TEMP TABLE neg AS
SELECT id, nombre, replace(nombre, 'PRUEBA GEN ', '') AS escenario
FROM negocios WHERE nombre LIKE 'PRUEBA GEN %';

-- Un escenario que no esté cargado devuelve NULL acá, y toda comprobación que
-- dependa de él se salta con un WHERE en vez de romper el banco: el perfil
-- `small` carga tres de los doce a propósito.
CREATE FUNCTION _neg(p text) RETURNS bigint LANGUAGE sql STABLE AS $$
    SELECT id FROM neg WHERE escenario = p;
$$;

CREATE TEMP TABLE contrato(escenario text, regla text, tipo text);
INSERT INTO contrato VALUES
 ('saludable','costo','prohibida'),
 ('saludable','proveedor','prohibida'),
 ('saludable','margen','prohibida'),
 ('saludable','agota','prohibida'),
 ('saludable','quieto','prohibida'),
 ('saludable','dependencia','prohibida'),
 ('saludable','sin_ventas','prohibida'),
 ('saludable','proveedor_sube','prohibida'),
 ('saludable','margen_cae','prohibida'),
 ('saludable','vs_ano_anterior','prohibida'),
 ('saludable','cartera','prohibida'),

 ('margen_bajo','margen','esperada'),
 ('margen_bajo','costo','prohibida'),
 ('margen_bajo','agota','prohibida'),

 ('costos_crecientes','costo','esperada'),
 ('costos_crecientes','proveedor_sube','esperada'),
 ('costos_crecientes','margen_cae','esperada'),
 ('costos_crecientes','margen','esperada'),
 ('costos_crecientes','quieto','prohibida'),

 ('inventario_excesivo','quieto','esperada'),
 ('inventario_excesivo','agota','prohibida'),

 ('productos_agotandose','agota','esperada'),
 ('productos_agotandose','quieto','prohibida'),

 ('proveedor_caro','proveedor','esperada'),
 ('proveedor_caro','cartera','esperada'),
 ('proveedor_caro','dependencia','prohibida'),

 ('ventas_decrecientes','sin_ventas','esperada'),
 ('ventas_decrecientes','vs_ano_anterior','esperada'),
 ('ventas_decrecientes','agota','prohibida'),

 ('ventas_crecientes','sin_ventas','prohibida'),
 ('ventas_crecientes','vs_ano_anterior','prohibida'),
 ('ventas_crecientes','margen','prohibida'),
 ('ventas_crecientes','costo','prohibida'),

 -- El falso positivo: una caída estacional legítima NO es un deterioro.
 ('estacional','vs_ano_anterior','prohibida'),
 ('estacional','sin_ventas','prohibida'),

 ('datos_incompletos','cartera','esperada'),
 ('datos_incompletos','agota','esperada'),

 ('multiples_proveedores','dependencia','esperada'),
 ('multiples_proveedores','proveedor','prohibida'),
 ('multiples_proveedores','cartera','prohibida'),

 ('accion_exitosa','margen','prohibida');

-- Lo DETECTADO por el motor, en modo registro: todo, sin el tope del informe.
CREATE TEMP TABLE detectado AS
SELECT n.escenario, e.regla, count(*) AS n
FROM neg n,
     LATERAL jsonb_to_recordset(recomendaciones_negocio(n.id, true))
       AS e(regla text)
GROUP BY 1, 2;

SELECT _chk('cargado/hay negocios generados', 'si',
  CASE WHEN (SELECT count(*) FROM neg) > 0 THEN 'si' ELSE 'no' END);

-- ---------------------------------------------------------------------------
-- Cada escenario dispara lo suyo y nada de lo prohibido
-- ---------------------------------------------------------------------------
SELECT _chk(format('%s/dispara %s', c.escenario, c.regla), 'si',
            CASE WHEN coalesce(d.n, 0) > 0 THEN 'si' ELSE 'no' END)
FROM contrato c
JOIN neg n ON n.escenario = c.escenario
LEFT JOIN detectado d ON d.escenario = c.escenario AND d.regla = c.regla
WHERE c.tipo = 'esperada';

SELECT _chk(format('%s/NO dispara %s', c.escenario, c.regla), 'si',
            CASE WHEN coalesce(d.n, 0) = 0 THEN 'si' ELSE 'no' END)
FROM contrato c
JOIN neg n ON n.escenario = c.escenario
LEFT JOIN detectado d ON d.escenario = c.escenario AND d.regla = c.regla
WHERE c.tipo = 'prohibida';

SELECT _warn(format('%s/no está cargado', c.escenario), 'perfil parcial')
FROM (SELECT DISTINCT escenario FROM contrato) c
WHERE NOT EXISTS (SELECT 1 FROM neg n WHERE n.escenario = c.escenario);

-- ===========================================================================
-- Ciclo de resultado: recomendación -> acción -> datos nuevos -> medición
-- ===========================================================================
SELECT _chk('accion_exitosa/la recomendación se cerró por acción del usuario',
  'accion_usuario',
  (SELECT cerrada_por FROM recomendaciones
    WHERE negocio_id = _neg('accion_exitosa') AND regla = 'margen'
      AND cerrada_en IS NOT NULL ORDER BY cerrada_en LIMIT 1))
WHERE _neg('accion_exitosa') IS NOT NULL;

SELECT _chk('accion_exitosa/el resultado se midió como positivo', 'positivo',
  (SELECT resultado FROM recomendaciones
    WHERE negocio_id = _neg('accion_exitosa') AND regla = 'margen'
      AND resultado IS NOT NULL ORDER BY id LIMIT 1))
WHERE _neg('accion_exitosa') IS NOT NULL;

SELECT _chk('accion_exitosa/el precio quedó en conocimiento', 'si',
  CASE WHEN EXISTS (SELECT 1 FROM conocimiento
                     WHERE negocio_id = _neg('accion_exitosa') AND tipo = 'precio')
       THEN 'si' ELSE 'no' END)
WHERE _neg('accion_exitosa') IS NOT NULL;

-- ===========================================================================
-- Reglas comparativas: necesitan historia y snapshots de verdad
-- ===========================================================================
SELECT _chk('costos_crecientes/hay al menos dos snapshots no parciales', 'si',
  CASE WHEN (SELECT count(*) FROM snapshots_negocio
              WHERE negocio_id = _neg('costos_crecientes')
                AND coalesce((metricas -> 'parcial')::boolean, false) = false) >= 2
       THEN 'si' ELSE 'no' END)
WHERE _neg('costos_crecientes') IS NOT NULL;

SELECT _chk('costos_crecientes/los snapshots tienen fechas distintas', 'si',
  CASE WHEN (SELECT count(DISTINCT fecha) FROM snapshots_negocio
              WHERE negocio_id = _neg('costos_crecientes')) >= 2
       THEN 'si' ELSE 'no' END)
WHERE _neg('costos_crecientes') IS NOT NULL;

SELECT _chk('ventas_decrecientes/tiene trece meses o más de historia visible', 'si',
  CASE WHEN (SELECT (max(fecha) - min(fecha)) FROM mov_visibles
              WHERE negocio_id = _neg('ventas_decrecientes')) >= 390
       THEN 'si' ELSE 'no' END)
WHERE _neg('ventas_decrecientes') IS NOT NULL;

-- ===========================================================================
-- Inventario: los tres orígenes y el conteo que contradice la estimación
-- ===========================================================================
SELECT _chk('inventario/aparecen los tres orígenes de stock',
  'calculado,conteo,estimado',
  (SELECT string_agg(DISTINCT o, ',' ORDER BY o)
     FROM (SELECT CASE origen_stock WHEN 'conteo' THEN 'conteo'
                                    WHEN 'calculado' THEN 'calculado'
                                    ELSE 'estimado' END AS o
             FROM v_balance_unidades b JOIN neg n ON n.id = b.negocio_id) s));

-- El producto que el conteo final contradijo: la estimación decía que había
-- inventario para meses y el conteo dice que queda una unidad. La
-- recomendación tiene que haber cambiado de `quieto` a `agota`.
CREATE TEMP TABLE contradice AS
SELECT ci.negocio_id, ci.producto_id
FROM conteos_inventario ci JOIN neg n ON n.id = ci.negocio_id
WHERE ci.unidades = 1;

SELECT _chk('inventario/el conteo contradictorio dejó el producto en `conteo`',
  'conteo',
  (SELECT b.origen_stock FROM v_balance_unidades b JOIN contradice c
     ON c.negocio_id = b.negocio_id AND c.producto_id = b.producto_id LIMIT 1))
WHERE EXISTS (SELECT 1 FROM contradice);

SELECT _chk('inventario/y con eso pasó a `agota`', 'si',
  CASE WHEN EXISTS (
    SELECT 1 FROM contradice c,
         LATERAL jsonb_to_recordset(recomendaciones_negocio(c.negocio_id, true))
           AS e(regla text, clave_objeto text)
     WHERE e.regla = 'agota'
       AND e.clave_objeto = 'producto:' || c.producto_id)
  THEN 'si' ELSE 'no' END)
WHERE EXISTS (SELECT 1 FROM contradice);

SELECT _chk('inventario/y dejó de ser `quieto`', 'no',
  CASE WHEN EXISTS (
    SELECT 1 FROM contradice c,
         LATERAL jsonb_to_recordset(recomendaciones_negocio(c.negocio_id, true))
           AS e(regla text, clave_objeto text)
     WHERE e.regla = 'quieto'
       AND e.clave_objeto = 'producto:' || c.producto_id)
  THEN 'si' ELSE 'no' END)
WHERE EXISTS (SELECT 1 FROM contradice);

-- ---------------------------------------------------------------------------
-- Matching sucio: lo que no se resuelve no desaparece
-- ---------------------------------------------------------------------------
SELECT _chk('matching/las filas sin producto siguen ahí', 'si',
  CASE WHEN (SELECT count(*) FROM movimientos
              WHERE negocio_id = _neg('datos_incompletos')
                AND producto_id IS NULL) > 0
       THEN 'si' ELSE 'no' END)
WHERE _neg('datos_incompletos') IS NOT NULL;

SELECT _chk('matching/y tienen alias pendiente, no NULL', 'si',
  CASE WHEN NOT EXISTS (SELECT 1 FROM movimientos m
                         WHERE m.negocio_id = _neg('datos_incompletos')
                           AND m.producto_id IS NULL AND m.alias_id IS NULL)
       THEN 'si' ELSE 'no' END)
WHERE _neg('datos_incompletos') IS NOT NULL;

SELECT _chk('matching/alias_pendientes() los reporta con su plata', 'si',
  CASE WHEN (SELECT count(*)
               FROM jsonb_to_recordset(alias_pendientes(_neg('datos_incompletos')))
                 AS a(texto text, dinero numeric)
              WHERE a.dinero > 0) > 0
       THEN 'si' ELSE 'no' END)
WHERE _neg('datos_incompletos') IS NOT NULL;

-- Confirmar un alias cambia los resultados HACIA ATRÁS: las filas ya cargadas
-- quedan resueltas sin volver a subir nada. Lo hace la propia función, no esta
-- prueba: acá solo se cuenta antes y después.
CREATE TEMP TABLE mat AS
SELECT (SELECT a.id FROM alias a
         WHERE a.negocio_id = _neg('datos_incompletos') AND a.producto_id IS NULL
         ORDER BY a.id LIMIT 1) AS alias_id,
       (SELECT p.id FROM productos p
         WHERE p.negocio_id = _neg('datos_incompletos')
         ORDER BY p.id LIMIT 1) AS producto_id;

CREATE TEMP TABLE mat_antes AS
SELECT count(*) AS n FROM movimientos m, mat
 WHERE m.negocio_id = _neg('datos_incompletos') AND m.alias_id = mat.alias_id
   AND m.producto_id IS NULL;

SELECT match_confirmar_alias(mat.alias_id, mat.producto_id) FROM mat
WHERE mat.alias_id IS NOT NULL AND mat.producto_id IS NOT NULL;

SELECT _chk('matching/había filas colgadas de ese alias', 'si',
  CASE WHEN (SELECT n FROM mat_antes) > 0 THEN 'si' ELSE 'no' END)
WHERE _neg('datos_incompletos') IS NOT NULL;

SELECT _chk('matching/confirmar el alias las resuelve retroactivamente', '0',
  (SELECT count(*)::text FROM movimientos m, mat
    WHERE m.negocio_id = _neg('datos_incompletos') AND m.alias_id = mat.alias_id
      AND m.producto_id IS NULL))
WHERE _neg('datos_incompletos') IS NOT NULL;

SELECT _chk('matching/el alias confirmado apunta al producto', 'si',
  CASE WHEN (SELECT a.producto_id FROM alias a, mat WHERE a.id = mat.alias_id)
          = (SELECT producto_id FROM mat)
       THEN 'si' ELSE 'no' END)
WHERE _neg('datos_incompletos') IS NOT NULL;

-- ===========================================================================
-- Aislamiento: una operación de un negocio no puede tocar a otro
-- ===========================================================================
SELECT _chk('aislamiento/ningún movimiento apunta a un producto ajeno', '0',
  (SELECT count(*)::text FROM movimientos m
     JOIN productos p ON p.id = m.producto_id
     JOIN neg n ON n.id = m.negocio_id
    WHERE p.negocio_id <> m.negocio_id));
SELECT _chk('aislamiento/ningún alias apunta a un producto ajeno', '0',
  (SELECT count(*)::text FROM alias a
     JOIN productos p ON p.id = a.producto_id
     JOIN neg n ON n.id = a.negocio_id
    WHERE p.negocio_id <> a.negocio_id));
SELECT _chk('aislamiento/ninguna factura apunta a un tercero ajeno', '0',
  (SELECT count(*)::text FROM facturas f
     JOIN terceros t ON t.id = f.tercero_id
     JOIN neg n ON n.id = f.negocio_id
    WHERE t.negocio_id <> f.negocio_id));
SELECT _chk('aislamiento/ningún conteo apunta a un producto ajeno', '0',
  (SELECT count(*)::text FROM conteos_inventario c
     JOIN productos p ON p.id = c.producto_id
     JOIN neg n ON n.id = c.negocio_id
    WHERE p.negocio_id <> c.negocio_id));
SELECT _chk('aislamiento/ninguna recomendación nombra un producto ajeno', '0',
  (SELECT count(*)::text FROM recomendaciones re
     JOIN neg n ON n.id = re.negocio_id
     JOIN productos p ON p.id = nullif(split_part(re.clave_objeto, ':', 2), '')::bigint
    WHERE re.clave_objeto LIKE 'producto:%' AND p.negocio_id <> re.negocio_id));
SELECT _chk('aislamiento/ningún snapshot mide un producto ajeno', '0',
  (SELECT count(*)::text
     FROM snapshots_negocio s
     JOIN neg n ON n.id = s.negocio_id,
          LATERAL jsonb_to_recordset(s.metricas -> 'margenes')
            AS e(producto_id bigint)
     JOIN productos p ON p.id = e.producto_id
    WHERE p.negocio_id <> s.negocio_id));
SELECT _chk('aislamiento/dos negocios generados no comparten nombre de producto', '0',
  (SELECT count(*)::text FROM productos a
     JOIN productos b ON b.nombre_canonico = a.nombre_canonico
                     AND b.negocio_id <> a.negocio_id
     JOIN neg na ON na.id = a.negocio_id
     JOIN neg nb ON nb.id = b.negocio_id));
SELECT _chk('aislamiento/dos negocios generados no comparten proveedor', '0',
  (SELECT count(*)::text FROM terceros a
     JOIN terceros b ON b.nombre = a.nombre AND b.negocio_id <> a.negocio_id
     JOIN neg na ON na.id = a.negocio_id
     JOIN neg nb ON nb.id = b.negocio_id
    WHERE a.nombre LIKE 'PROVEEDOR DEMO %'));

-- ===========================================================================
-- Alertas: una por corrida, sin repetir por cooldown
-- ===========================================================================
-- `alertas_evaluar()` no evalúa fuera de la franja 8–20 de America/Bogota: a
-- las tres de la mañana devuelve vacío y una prueba que exigiera una alerta
-- daría un falso negativo. Por eso acá el fuera de horario es un [WARN].
-- Y tampoco hay nada que alertar si ningún negocio cargado tiene una
-- recomendación de prioridad `alta`: `alertas_evaluar` solo mira esas. En el
-- perfil `small` eso pasa a propósito, así que también es un [WARN].
CREATE TEMP TABLE hay_alta AS
SELECT EXISTS (
  SELECT 1 FROM neg n,
       LATERAL jsonb_to_recordset(recomendaciones_negocio(n.id, true))
         AS e(prioridad text)
   WHERE e.prioridad = 'alta') AS v;

SELECT _warn('alertas/ningún negocio cargado tiene una recomendación alta',
             'nada que alertar')
WHERE NOT (SELECT v FROM hay_alta);

CREATE TEMP TABLE a1 AS SELECT alertas_evaluar() AS j;
SELECT _warn('alertas/corrida fuera de la franja horaria', 'no evaluadas')
WHERE (SELECT (j ->> 'fuera_de_horario')::boolean FROM a1);

SELECT _chk('alertas/1 la primera corrida emite alguna', 'si',
  CASE WHEN jsonb_array_length((SELECT j -> 'notificaciones' FROM a1)) > 0
       THEN 'si' ELSE 'no' END)
WHERE NOT coalesce((SELECT (j ->> 'fuera_de_horario')::boolean FROM a1), false)
  AND (SELECT v FROM hay_alta);

CREATE TEMP TABLE a2 AS SELECT alertas_evaluar() AS j;

-- El cooldown se comprueba donde vive: `alertas_enviadas`. Comparar los textos
-- de las notificaciones no serviría —dos reglas distintas del mismo producto
-- llevan el mismo título— y lo que la regla promete es que un mismo par
-- (regla, objeto) no se repita antes de que pasen los días de cooldown.
SELECT _chk('alertas/2 ningún par (regla, objeto) se repitió por cooldown', '0',
  (SELECT count(*)::text FROM (
     SELECT al.negocio_id, al.regla, al.clave_objeto
       FROM alertas_enviadas al JOIN neg n ON n.id = al.negocio_id
      WHERE al.enviada_en > now() - make_interval(
              days => coalesce((parametro(NULL,'alerta_cooldown_dias'))::text::int, 14))
      GROUP BY 1,2,3 HAVING count(*) > 1) x))
WHERE NOT coalesce((SELECT (j ->> 'fuera_de_horario')::boolean FROM a1), false)
  AND (SELECT v FROM hay_alta);

SELECT _chk('alertas/2b la segunda corrida no vuelve a emitir lo mismo', 'si',
  CASE WHEN jsonb_array_length((SELECT j -> 'notificaciones' FROM a2))
          <= jsonb_array_length((SELECT j -> 'notificaciones' FROM a1))
       THEN 'si' ELSE 'no' END)
WHERE NOT coalesce((SELECT (j ->> 'fuera_de_horario')::boolean FROM a1), false)
  AND (SELECT v FROM hay_alta);

SELECT _chk('alertas/3 quedaron registradas en alertas_enviadas', 'si',
  CASE WHEN EXISTS (SELECT 1 FROM alertas_enviadas al JOIN neg n ON n.id = al.negocio_id)
       THEN 'si' ELSE 'no' END)
WHERE NOT coalesce((SELECT (j ->> 'fuera_de_horario')::boolean FROM a1), false)
  AND (SELECT v FROM hay_alta);

-- ===========================================================================
-- Informe periódico: el primero siempre lo pide el dueño
-- ===========================================================================
SELECT _chk('periodico/1 un negocio sin análisis previo no se lista', 'no',
  CASE WHEN EXISTS (SELECT 1 FROM v_negocios_informe_periodico
                     WHERE negocio_id = (SELECT min(id) FROM neg)) THEN 'si' ELSE 'no' END);

INSERT INTO ejecuciones (negocio_id, servicio_codigo, estado, inicio, fin)
SELECT min(id), 'ventas_compras', 'completada',
       now() - interval '41 days', now() - interval '40 days' FROM neg;

SELECT _chk('periodico/2 con análisis viejo y datos nuevos sí se lista', 'si',
  CASE WHEN EXISTS (SELECT 1 FROM v_negocios_informe_periodico
                     WHERE negocio_id = (SELECT min(id) FROM neg)) THEN 'si' ELSE 'no' END);
SELECT _chk('periodico/3 y trae al menos diez movimientos nuevos', 'si',
  CASE WHEN (SELECT movs_nuevos FROM v_negocios_informe_periodico
              WHERE negocio_id = (SELECT min(id) FROM neg)) >= 10 THEN 'si' ELSE 'no' END);

-- ===========================================================================
-- Salud e informe: que el negocio generado produzca un informe completo
-- ===========================================================================
-- Las seis notas de `salud_negocio` son seis claves del objeto, no un array.
SELECT _chk('informe/la salud tiene las seis notas', '6',
  (SELECT count(*)::text FROM jsonb_object_keys(salud_negocio((SELECT min(id) FROM neg))) k
    WHERE k IN ('ventas','margenes','inventario','compras','riesgos','liquidez')));
SELECT _chk('informe/los hallazgos traen números', 'si',
  CASE WHEN hallazgos_generar((SELECT min(id) FROM neg)) -> 'resumen' IS NOT NULL
       THEN 'si' ELSE 'no' END);
SELECT _chk('informe/una cifra inventada se rechaza', 'false',
  (validar_cifras('Vendiste 987.654.321.987 pesos',
                  hallazgos_generar((SELECT min(id) FROM neg))) ->> 'ok'));

-- ===========================================================================
-- Resultado
-- ===========================================================================
\echo ''
\echo '=== ESCENARIOS GENERADOS ==='
SELECT nivel, prueba, coalesce(esperado, '(NULL)') AS esperado,
       coalesce(obtenido, '(NULL)') AS obtenido
FROM r ORDER BY (nivel = 'FAIL') DESC, prueba;

SELECT count(*) FILTER (WHERE nivel = 'PASS') AS pasaron,
       count(*) FILTER (WHERE nivel = 'FAIL') AS fallaron,
       count(*) FILTER (WHERE nivel = 'WARN') AS avisos,
       count(*) AS total
FROM r;

ROLLBACK;
