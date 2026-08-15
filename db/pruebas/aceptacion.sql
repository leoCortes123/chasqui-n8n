-- Las pruebas de aceptación del roadmap (§7), en un solo lugar.
--
-- Corre entera dentro de una transacción que se descarta: no deja rastro y se
-- puede correr contra producción.
--
--   set -a; . ./.env; set +a
--   docker compose exec -T -e PGPASSWORD="$CHASQUI_DB_PASSWORD" postgres \
--     psql -U "$CHASQUI_DB_USER" -d "$CHASQUI_DB" < db/pruebas/aceptacion.sql
--
-- Lo que NO cubre: las corridas contra el LLM real (que la respuesta narrada no
-- caiga al informe seco). Eso se prueba con `wf_ejecutar` y está registrado en
-- el ROADMAP, porque cuesta tokens y depende del proveedor.
\set ON_ERROR_STOP on
\pset format aligned
BEGIN;

CREATE TEMP TABLE r(prueba text, esperado text, obtenido text, ok boolean);
CREATE FUNCTION _chk(p text, esp text, obt text) RETURNS void LANGUAGE sql AS $$
    INSERT INTO r VALUES (p, esp, obt, esp IS NOT DISTINCT FROM obt);
$$;

-- ===========================================================================
-- Fixture: un negocio con historia
-- ===========================================================================
INSERT INTO negocios (nombre, plan) VALUES ('PRUEBA aceptación', 'pro')
RETURNING id AS neg \gset
INSERT INTO usuarios (negocio_id, telegram_user_id, telegram_chat_id, rol,
                      autorizacion_datos, autorizacion_fecha)
VALUES (:neg, 999001, 999001, 'dueno', true, now()) RETURNING id AS usr \gset
INSERT INTO productos (negocio_id, nombre_canonico, unidad)
VALUES (:neg, 'PRODUCTO PRUEBA', 'und') RETURNING id AS prod \gset

-- Compras caras y ventas baratas: margen por debajo del mínimo.
INSERT INTO movimientos (negocio_id, tipo, fecha, producto_id, cantidad,
                         valor_unitario, valor_total, raw)
SELECT :neg, 'compra'::tipo_movimiento, current_date - 60 + g*10, :prod, 20, 9000, 180000,
       jsonb_build_object('proveedor','Proveedor Único')
FROM generate_series(0,4) g
UNION ALL
SELECT :neg, 'venta'::tipo_movimiento, current_date - 55 + g*8, :prod, 8, 10000, 80000, '{}'::jsonb
FROM generate_series(0,5) g;

-- ===========================================================================
-- PRUEBA DE MEMORIA — recomendación → acción → resultado
-- ===========================================================================
-- "Ejecutar Mes 1 → recomendación, Mes 2 → acción, Mes 3 → resultado, y
--  comprobar que Chasqui reconstruye la secuencia completa."

-- Mes 1: se detecta y se registra.
SELECT recomendaciones_registrar(:neg);
SELECT _chk('memoria/1 se detectó el margen bajo', 'si',
  CASE WHEN EXISTS (SELECT 1 FROM recomendaciones
                     WHERE negocio_id = :neg AND regla = 'margen'
                       AND estado IN ('nueva','vigente'))
       THEN 'si' ELSE 'no' END);

SELECT id AS rid FROM recomendaciones
WHERE negocio_id = :neg AND regla = 'margen' ORDER BY id LIMIT 1 \gset

-- Mes 2: el dueño aplica el precio sugerido.
SELECT _chk('memoria/2 la acción se aplicó', 'true',
  (recomendacion_accion(:rid, :neg, 'precio', :usr) ->> 'ok'));
SELECT _chk('memoria/2 cerrada por acción del usuario', 'accion_usuario',
  (SELECT cerrada_por FROM recomendaciones WHERE id = :rid));
SELECT _chk('memoria/2 el precio quedó en conocimiento', 'si',
  CASE WHEN EXISTS (SELECT 1 FROM conocimiento
                     WHERE negocio_id = :neg AND tipo = 'precio')
       THEN 'si' ELSE 'no' END);

-- Mes 3: entran datos nuevos donde el margen mejoró, y se mide.
UPDATE recomendaciones SET cerrada_en = now() - interval '30 days' WHERE id = :rid;
INSERT INTO movimientos (negocio_id, tipo, fecha, producto_id, cantidad,
                         valor_unitario, valor_total, raw)
VALUES (:neg, 'venta', current_date, :prod, 5, 15000, 75000, '{}'::jsonb);
SELECT recomendaciones_medir(:neg);
SELECT _chk('memoria/3 el resultado se midió', 'positivo',
  (SELECT resultado FROM recomendaciones WHERE id = :rid));

-- Y la secuencia entera se puede reconstruir.
SELECT _chk('memoria/4 el perfil cuenta la acción', '1',
  (perfil_negocio(:neg) #>> '{acciones,por_accion}'));
SELECT _chk('memoria/4 el perfil cuenta el resultado', '1',
  (perfil_negocio(:neg) #>> '{resultados,positivo}'));

-- ===========================================================================
-- PRUEBA DE VERDAD — una cifra inventada se rechaza
-- ===========================================================================
SELECT _chk('verdad/1 una cifra inventada se detecta', 'false',
  (validar_cifras('El margen fue de 987.654.321 pesos',
                  hallazgos_generar(:neg)) ->> 'ok'));
SELECT _chk('verdad/2 una cifra real se acepta', 'true',
  (validar_cifras(
     format('El margen quedó en %s%%',
       fmt_decimal((hallazgos_generar(:neg) #>> '{resumen,margen_promedio_pct}')::numeric)),
     hallazgos_generar(:neg)) ->> 'ok'));

-- ===========================================================================
-- R-II — el plan limita lectura, no almacenamiento
-- ===========================================================================
-- Un movimiento de hace un año, fuera de cualquier ventana gratuita.
INSERT INTO movimientos (negocio_id, tipo, fecha, producto_id, cantidad,
                         valor_unitario, valor_total, raw)
VALUES (:neg, 'venta', current_date - 400, :prod, 1, 10000, 10000, '{}'::jsonb);

UPDATE negocios SET plan = 'free' WHERE id = :neg;
-- Con plan free ese movimiento SIGUE almacenado...
SELECT _chk('R-II/1 el dato viejo se guardó igual', 'si',
  CASE WHEN EXISTS (SELECT 1 FROM movimientos
                     WHERE negocio_id = :neg AND fecha = current_date - 400)
       THEN 'si' ELSE 'no' END);
-- ...pero NO se analiza.
SELECT _chk('R-II/2 el plan free no lo analiza', 'no',
  CASE WHEN EXISTS (SELECT 1 FROM mov_visibles
                     WHERE negocio_id = :neg AND fecha = current_date - 400)
       THEN 'si' ELSE 'no' END);

UPDATE negocios SET plan = 'pro' WHERE id = :neg;
-- Al ampliar el plan aparece solo, sin volver a cargar nada.
SELECT _chk('R-II/3 al ampliar el plan entra solo', 'si',
  CASE WHEN EXISTS (SELECT 1 FROM mov_visibles
                     WHERE negocio_id = :neg AND fecha = current_date - 400)
       THEN 'si' ELSE 'no' END);

-- ===========================================================================
-- Las ocho preguntas: que cada una encuentre su camino
-- ===========================================================================
SELECT _chk('pregunta/3 más rentable',  'utilidad',        intencion_detectar('¿cuál es mi producto más rentable?'));
SELECT _chk('pregunta/4 poco margen',   'margen',          intencion_detectar('¿qué producto me deja poco margen?'));
SELECT _chk('pregunta/5 subió el costo','costo',           intencion_detectar('¿a qué producto le subió el costo?'));
SELECT _chk('pregunta/6 quieto',        'cobertura',       intencion_detectar('¿qué se me está quedando quieto?'));
SELECT _chk('pregunta/7 cuánto vendí',  'ventas',          intencion_detectar('¿cuánto vendí en marzo?'));
SELECT _chk('pregunta/8 a quién compré','compras',         intencion_detectar('¿cuánto le compré a mi proveedor?'));
-- Las dos abiertas las contesta el contexto de C1, sin intención: NULL es lo
-- correcto y no un fallo.
SELECT _chk('pregunta/1 cómo está (abierta)', NULL, intencion_detectar('¿cómo está mi negocio?'));
SELECT _chk('pregunta/2 qué hago (abierta)',  NULL, intencion_detectar('¿qué debería hacer primero?'));

-- Y que el contexto que se le da al modelo traiga los números.
SELECT _chk('contexto/1 trae el estado', 'si',
  CASE WHEN contexto_negocio_recuperar(:neg, '{"pregunta":"¿cómo está mi negocio?"}'::jsonb)
            -> 'estado' IS NOT NULL THEN 'si' ELSE 'no' END);
SELECT _chk('contexto/2 trae las recomendaciones', 'si',
  CASE WHEN jsonb_array_length(contexto_negocio_recuperar(:neg, '{"pregunta":"x"}'::jsonb)
            -> 'recomendaciones') >= 0 THEN 'si' ELSE 'no' END);
SELECT _chk('contexto/3 resuelve la intención', 'ventas',
  contexto_negocio_recuperar(:neg, '{"pregunta":"¿cuánto vendí?"}'::jsonb)
    #>> '{consulta,intencion}');

-- ===========================================================================
-- Resultado
-- ===========================================================================
\echo ''
\echo '=== PRUEBAS DE ACEPTACIÓN ==='
SELECT prueba, coalesce(esperado,'(NULL)') AS esperado,
       coalesce(obtenido,'(NULL)') AS obtenido,
       CASE WHEN ok THEN 'OK' ELSE 'FALLA' END AS estado
FROM r ORDER BY prueba;

SELECT count(*) FILTER (WHERE ok) AS pasaron,
       count(*) FILTER (WHERE NOT ok) AS fallaron,
       count(*) AS total
FROM r;

ROLLBACK;
