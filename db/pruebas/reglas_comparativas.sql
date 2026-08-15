-- Prueba de las cuatro reglas comparativas (060, Nivel 1 completo).
--
-- Arma un negocio sintético con 15 meses de historia, cada producto diseñado
-- para disparar exactamente una regla, y comprueba que dispara la que le toca
-- y ninguna más. Corre entero dentro de una transacción que se descarta: no
-- deja rastro y se puede correr contra producción.
--
--   set -a; . ./.env; set +a
--   docker compose exec -T -e PGPASSWORD="$CHASQUI_DB_PASSWORD" postgres \
--     psql -U "$CHASQUI_DB_USER" -d "$CHASQUI_DB" < db/pruebas/reglas_comparativas.sql
--
-- Las fechas se anclan a `current_date`, así que la prueba no caduca.
\set ON_ERROR_STOP on
BEGIN;

-- El último día del mes pasado: así el "mes de referencia" de R10 es un mes
-- COMPLETO, que es lo único que se puede comparar contra el año anterior.
CREATE TEMP TABLE t AS
SELECT (date_trunc('month', current_date) - interval '1 day')::date AS fin,
       (date_trunc('month', current_date) - interval '1 month')::date AS mes_ref;

INSERT INTO negocios (nombre, plan) VALUES ('PRUEBA comparativas', 'pro')
RETURNING id AS neg \gset

INSERT INTO productos (negocio_id, nombre_canonico, unidad) VALUES
  (:neg, 'PROD-A SE PARO',      'und'),
  (:neg, 'PROD-B PROV SUBE',    'und'),
  (:neg, 'PROD-C MARGEN CAE',   'und'),
  (:neg, 'PROD-D ESTABLE',      'und');

CREATE TEMP TABLE p AS
SELECT max(id) FILTER (WHERE nombre_canonico = 'PROD-A SE PARO')    AS a,
       max(id) FILTER (WHERE nombre_canonico = 'PROD-B PROV SUBE')  AS b,
       max(id) FILTER (WHERE nombre_canonico = 'PROD-C MARGEN CAE') AS c,
       max(id) FILTER (WHERE nombre_canonico = 'PROD-D ESTABLE')    AS d
FROM productos WHERE negocio_id = :neg;

-- ---------------------------------------------------------------------------
-- R7 — PROD-A: se vendía cada 10 días y hace 4 meses no se mueve.
-- ---------------------------------------------------------------------------
INSERT INTO movimientos (negocio_id, tipo, fecha, producto_id, cantidad,
                         valor_unitario, valor_total, raw)
SELECT :neg, 'venta', (SELECT fin FROM t) - (120 + g * 10), (SELECT a FROM p),
       2, 5000, 10000, '{}'::jsonb
FROM generate_series(0, 9) g;

-- ---------------------------------------------------------------------------
-- R8 — PROD-B: el mismo proveedor sube el precio en cada una de 5 compras.
-- ---------------------------------------------------------------------------
INSERT INTO movimientos (negocio_id, tipo, fecha, producto_id, cantidad,
                         valor_unitario, valor_total, raw)
SELECT :neg, 'compra', (SELECT fin FROM t) - (330 - g * 65), (SELECT b FROM p),
       10, 1000 + g * 200, (1000 + g * 200) * 10,
       jsonb_build_object('proveedor', 'Proveedor Caro')
FROM generate_series(0, 4) g;
-- Y se vende, para que tenga ritmo y no dispare R7.
INSERT INTO movimientos (negocio_id, tipo, fecha, producto_id, cantidad,
                         valor_unitario, valor_total, raw)
SELECT :neg, 'venta', (SELECT fin FROM t) - g * 15, (SELECT b FROM p),
       3, 2600, 7800, '{}'::jsonb
FROM generate_series(0, 6) g;

-- ---------------------------------------------------------------------------
-- R9 — PROD-C: hoy deja 18% de margen; los dos snapshots previos, 25% y 22%.
-- ---------------------------------------------------------------------------
INSERT INTO movimientos (negocio_id, tipo, fecha, producto_id, cantidad,
                         valor_unitario, valor_total, raw)
VALUES (:neg, 'compra', (SELECT fin FROM t) - 20, (SELECT c FROM p),
        10, 8200, 82000, jsonb_build_object('proveedor', 'Proveedor Normal'));
INSERT INTO movimientos (negocio_id, tipo, fecha, producto_id, cantidad,
                         valor_unitario, valor_total, raw)
SELECT :neg, 'venta', (SELECT fin FROM t) - g * 12, (SELECT c FROM p),
       4, 10000, 40000, '{}'::jsonb
FROM generate_series(0, 8) g;

INSERT INTO snapshots_negocio (negocio_id, fecha, version, periodo, salud, metricas, origen)
SELECT :neg, (SELECT fin FROM t) - 30, snapshot_version(), NULL::daterange, '{"indice": 70}'::jsonb,
       jsonb_build_object('margenes', jsonb_build_array(
         jsonb_build_object('producto_id', (SELECT c FROM p), 'margen_pct', 22))), 'manual'
UNION ALL
SELECT :neg, (SELECT fin FROM t) - 60, snapshot_version(), NULL::daterange, '{"indice": 75}'::jsonb,
       jsonb_build_object('margenes', jsonb_build_array(
         jsonb_build_object('producto_id', (SELECT c FROM p), 'margen_pct', 25))), 'manual';

-- ---------------------------------------------------------------------------
-- R10 — PROD-D: el mes de referencia vende bastante menos que un año antes.
-- ---------------------------------------------------------------------------
INSERT INTO movimientos (negocio_id, tipo, fecha, producto_id, cantidad,
                         valor_unitario, valor_total, raw)
SELECT :neg, 'venta'::tipo_movimiento,
       ((SELECT mes_ref FROM t) - interval '1 year' + (g || ' days')::interval)::date,
       (SELECT d FROM p), 10, 5000, 50000, '{}'::jsonb
FROM generate_series(0, 19) g
UNION ALL
SELECT :neg, 'venta'::tipo_movimiento,
       ((SELECT mes_ref FROM t) + (g || ' days')::interval)::date,
       (SELECT d FROM p), 10, 5000, 50000, '{}'::jsonb
FROM generate_series(0, 9) g;
-- Compras de PROD-D, para que tenga costo y no ensucie otras reglas.
INSERT INTO movimientos (negocio_id, tipo, fecha, producto_id, cantidad,
                         valor_unitario, valor_total, raw)
SELECT :neg, 'compra', (SELECT mes_ref FROM t) - (g * 40), (SELECT d FROM p),
       120, 4000, 480000, jsonb_build_object('proveedor', 'Proveedor Normal')
FROM generate_series(0, 8) g;

-- ---------------------------------------------------------------------------
-- Resultado
-- ---------------------------------------------------------------------------
\echo '=== Reglas que dispararon ==='
SELECT e.regla, e.titulo, e.prioridad, e.impacto_mes, left(e.problema, 95) AS problema
FROM jsonb_to_recordset(recomendaciones_negocio(:neg, true))
  AS e(regla text, titulo text, prioridad text, impacto_mes numeric, problema text)
WHERE e.regla IN ('sin_ventas','proveedor_sube','margen_cae','vs_ano_anterior')
ORDER BY e.regla;

\echo '=== Las cuatro comparativas, una por una ==='
SELECT r AS regla_esperada,
       EXISTS (SELECT 1 FROM jsonb_to_recordset(recomendaciones_negocio(:neg, true))
                        AS e(regla text) WHERE e.regla = r) AS disparo
FROM unnest(ARRAY['sin_ventas','proveedor_sube','margen_cae','vs_ano_anterior']) r;

\echo '=== El comparativo que va a los hallazgos ==='
SELECT jsonb_pretty(hallazgos_comparativo(:neg));

ROLLBACK;
