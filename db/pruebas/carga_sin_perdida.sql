-- Banco de la 071: ningún archivo que el usuario mande se descarta.
--
-- El caso central reproduce el bug medido en la segunda prueba de usuario: el
-- usuario tocó Analizar con archivos todavía en vuelo, la sesión pasó a
-- 'procesando' y los 38 documentos que llegaron después se contestaron y se
-- tiraron. Acá eso es una aserción: un evento con documento SIEMPRE tiene que
-- producir una acción `ingerir`, esté la sesión en el estado que esté.
--
-- Corre entero dentro de una transacción que se descarta: no deja rastro y se
-- puede correr contra producción.
--
--   set -a; . ./.env; set +a
--   docker compose exec -T -e PGPASSWORD="$CHASQUI_DB_PASSWORD" postgres \
--     psql -U "$CHASQUI_DB_USER" -d "$CHASQUI_DB" < db/pruebas/carga_sin_perdida.sql
\set ON_ERROR_STOP on
\pset format aligned
BEGIN;

CREATE TEMP TABLE r(prueba text, esperado text, obtenido text, ok boolean);
CREATE FUNCTION _chk(p text, esp text, obt text) RETURNS void LANGUAGE sql AS $$
    INSERT INTO r VALUES (p, esp, obt, esp IS NOT DISTINCT FROM obt);
$$;

-- ¿La respuesta del router trae una acción de este tipo?
CREATE FUNCTION _tiene_accion(p_res jsonb, p_tipo text) RETURNS text LANGUAGE sql AS $$
    SELECT CASE WHEN EXISTS (
             SELECT 1 FROM jsonb_array_elements(coalesce(p_res -> 'acciones','[]'::jsonb)) a
              WHERE a ->> 'tipo' = p_tipo) THEN 'si' ELSE 'no' END;
$$;

-- ===========================================================================
-- Fixture: un negocio con un usuario autorizado y una carga abierta
-- ===========================================================================
INSERT INTO negocios (nombre, plan) VALUES ('PRUEBA carga', 'free')
RETURNING id AS neg \gset
INSERT INTO usuarios (negocio_id, telegram_user_id, telegram_chat_id, rol,
                      autorizacion_datos, autorizacion_fecha)
VALUES (:neg, 999501, 999501, 'dueno', true, now()) RETURNING id AS usr \gset
-- `usuario_de_canal` resuelve por `identidades`, no por usuarios.telegram_user_id:
-- sin esta fila crearía un usuario nuevo y el fixture no serviría de nada.
INSERT INTO identidades (canal, id_externo, usuario_id, datos)
VALUES ('telegram', '999501', :usr, '{"chat_id":"999501"}'::jsonb);
INSERT INTO sesiones (usuario_id, negocio_id, servicio_codigo, estado, paso)
VALUES (:usr, :neg, 'ventas_compras', 'recibiendo', 'cargar_archivos')
RETURNING id AS ses \gset

CREATE FUNCTION _ev(p_texto text, p_doc boolean DEFAULT false)
RETURNS jsonb LANGUAGE sql AS $$
    SELECT jsonb_build_object(
      'chat', jsonb_build_object('id', 999501),
      'from', jsonb_build_object('id', 999501, 'username', 'prueba_carga'),
      'texto', p_texto, 'tiene_documento', p_doc);
$$;

-- Un documento ya cargado, para que la sesión tenga con qué analizar. La fecha
-- de creación se mueve a mano en cada caso: es lo que decide el silencio.
INSERT INTO documentos (sesion_id, negocio_id, nombre_archivo, mime, hash,
                        contenido, tamano, estado, formato_codigo)
VALUES (:ses, :neg, 'compras_01.xml', 'text/xml', '\x01'::bytea,
        '\x01'::bytea, 1, 'parseado', 'dian_xml')
RETURNING id AS doc \gset

-- ===========================================================================
-- EL BUG DE LOS 38 ARCHIVOS
-- ===========================================================================
-- Con la sesión en 'procesando', un documento tiene que seguir entrando. Antes
-- de la 071 esto devolvía 'ejecucion.ya_en_curso' y ninguna acción.
UPDATE sesiones SET estado = 'procesando', paso = 'ejecutando' WHERE id = :ses;

SELECT _chk('doc durante procesando -> ingerir', 'si',
  _tiene_accion(router_procesar_mensaje(_ev('', true)), 'ingerir'));

SELECT _chk('texto durante procesando -> sin ingerir', 'no',
  _tiene_accion(router_procesar_mensaje(_ev('hola')), 'ingerir'));

-- Y sigue sin dispararse una segunda corrida, que es para lo que existía la
-- compuerta: el documento entra, la ejecución no se duplica.
SELECT _chk('doc durante procesando -> sin ejecutar', 'no',
  _tiene_accion(router_procesar_mensaje(_ev('', true)), 'ejecutar'));

UPDATE sesiones SET estado = 'recibiendo', paso = 'cargar_archivos' WHERE id = :ses;

-- ===========================================================================
-- EL BOTÓN AGENDA, NO DISPARA
-- ===========================================================================
-- Archivo recién llegado: Analizar no puede arrancar todavía.
UPDATE documentos SET creado_en = now() WHERE id = :doc;

SELECT _chk('/listo con archivos llegando -> no ejecuta', 'no',
  _tiene_accion(router_h_recibiendo(
      router_ctx(_ev('/listo')) || jsonb_build_object(
        'sesion_id', :ses, 'sesion_estado','recibiendo',
        'sesion_paso','cargar_archivos', 'sesion_servicio','ventas_compras')),
    'ejecutar'));

SELECT _chk('/listo con archivos llegando -> deja la marca', 'si',
  CASE WHEN (SELECT analisis_pedido_en FROM sesiones WHERE id = :ses) IS NOT NULL
       THEN 'si' ELSE 'no' END);

SELECT _chk('sesión sigue recibiendo, no procesando', 'recibiendo',
  (SELECT estado::text FROM sesiones WHERE id = :ses));

SELECT _chk('carga_evaluar con archivo reciente -> nada', 'nada',
  carga_evaluar(:ses) ->> 'accion');

-- Ahora el silencio: el archivo envejece más allá del umbral.
UPDATE documentos SET creado_en = now() - interval '60 seconds' WHERE id = :doc;

SELECT _chk('carga_evaluar con silencio y botón -> analizar', 'analizar',
  carga_evaluar(:ses) ->> 'accion');

SELECT _chk('ahora sí quedó procesando', 'procesando',
  (SELECT estado::text FROM sesiones WHERE id = :ses));

-- Exclusión mutua: dos ejecuciones de wf_ingesta que despiertan juntas.
SELECT _chk('carga_arrancar dos veces -> la segunda NULL', 'NULL',
  coalesce(carga_arrancar(:ses)::text, 'NULL'));

SELECT _chk('una sola ejecución creada', '1',
  (SELECT count(*)::text FROM ejecuciones WHERE sesion_id = :ses));

-- ===========================================================================
-- SILENCIO SIN BOTÓN: solo se refresca el panel
-- ===========================================================================
-- `panel_pedido_en` se limpia a propósito: el caso anterior salió por una rama
-- que la anota (075), y entrar acá con un panel "en vuelo" de hace un segundo
-- haría que la compuerta devuelva 'nada' y este caso mediría otra cosa.
UPDATE sesiones SET estado = 'recibiendo', paso = 'cargar_archivos',
                    analisis_pedido_en = NULL, panel_pedido_en = NULL,
                    panel_mensaje_id = NULL WHERE id = :ses;
DELETE FROM ejecuciones WHERE sesion_id = :ses;

SELECT _chk('silencio sin botón -> panel', 'panel',
  carga_evaluar(:ses) ->> 'accion');

SELECT _chk('panel no arrancó nada', 'recibiendo',
  (SELECT estado::text FROM sesiones WHERE id = :ses));

-- ===========================================================================
-- PANEL EN VUELO (075 y 076): el lock que no tenía banco
-- ===========================================================================
-- El bug medido en la sesión 40 (101 archivos, 2026-08-19): seis ejecuciones de
-- wf_ingesta despertaron dentro de la misma ventana de 0,76 s, las seis vieron
-- el mismo silencio y las seis crearon un panel. El usuario vio cuatro. La 075
-- serializa `carga_evaluar` con un advisory lock y anota `panel_pedido_en`;
-- mientras el panel está pedido y Telegram no devolvió el message_id con el que
-- se edita, nadie pide otro.
UPDATE sesiones SET panel_pedido_en = now(), panel_mensaje_id = NULL
 WHERE id = :ses;
SELECT _chk('panel en vuelo -> no se crea un segundo panel', 'nada',
  carga_evaluar(:ses) ->> 'accion');

-- Y la marca no puede ser una trampa permanente: si Telegram nunca contesta,
-- pasados `carga_panel_en_vuelo_segundos` (30) el panel se vuelve a intentar.
-- Sin esta aserción, un panel en vuelo eterno dejaría la carga muda para
-- siempre y el banco no lo vería.
UPDATE sesiones SET panel_pedido_en = now() - interval '31 seconds'
 WHERE id = :ses;
SELECT _chk('panel en vuelo vencido -> se reintenta', 'panel',
  carga_evaluar(:ses) ->> 'accion');

-- Con el message_id ya escrito la compuerta no aplica: el panel se edita en su
-- lugar, que es lo que pide INGESTA-002 —un mensaje que se edita, no uno por
-- archivo—.
UPDATE sesiones SET panel_pedido_en = now(), panel_mensaje_id = 4242
 WHERE id = :ses;
SELECT _chk('panel ya publicado -> se refresca, no se duplica', 'panel',
  carga_evaluar(:ses) ->> 'accion');

UPDATE sesiones SET panel_pedido_en = NULL, panel_mensaje_id = NULL
 WHERE id = :ses;

-- ===========================================================================
-- EL PANEL CUENTA LO QUE ENTRÓ
-- ===========================================================================
INSERT INTO documentos (sesion_id, negocio_id, nombre_archivo, mime, hash,
                        contenido, tamano, estado, formato_codigo)
VALUES (:ses, :neg, 'compras_02.xml', 'text/xml', '\x02'::bytea,
        '\x02'::bytea, 1, 'parseado', 'dian_xml'),
       (:ses, :neg, 'catalogo.pdf',   'application/pdf', '\x03'::bytea,
        '\x03'::bytea, 1, 'error', NULL),
       (:ses, :neg, 'ventas_08.csv',  'text/csv', '\x04'::bytea,
        '\x04'::bytea, 1, 'pendiente', NULL);

SELECT _chk('panel cuenta 2 parseados', '2',
  carga_resumen(:ses) ->> 'archivos');
SELECT _chk('panel cuenta 1 fallado', '1',
  carga_resumen(:ses) ->> 'fallados');
SELECT _chk('panel cuenta 1 pendiente', '1',
  carga_resumen(:ses) ->> 'pendientes');
SELECT _chk('el fallado se nombra en el panel', 'si',
  CASE WHEN (carga_panel(:ses) ->> 'texto') LIKE '%catalogo.pdf%'
       THEN 'si' ELSE 'no' END);
SELECT _chk('el pendiente se avisa en el panel', 'si',
  CASE WHEN (carga_panel(:ses) ->> 'texto') LIKE '%No los perdés%'
       THEN 'si' ELSE 'no' END);
SELECT _chk('el panel trae el botón Analizar', 'si',
  CASE WHEN (carga_panel(:ses) -> 'teclado')::text LIKE '%/listo%'
       THEN 'si' ELSE 'no' END);
SELECT _chk('el panel esperando NO trae Analizar', 'no',
  CASE WHEN (carga_panel(:ses, 'esperando') -> 'teclado')::text LIKE '%/listo%'
       THEN 'si' ELSE 'no' END);

-- El archivo que no se pudo bajar no tiene fila en documentos: si no se anotara
-- en la sesión sería una pérdida silenciosa, que es justo lo que arregla la 071.
SELECT carga_registrar_fallo(:ses, 'ventas_09.csv');
SELECT _chk('el no bajado se cuenta', '1',
  carga_resumen(:ses) ->> 'no_bajados');
SELECT _chk('el no bajado se nombra y se pide reenviar', 'si',
  CASE WHEN (carga_panel(:ses) ->> 'texto') LIKE '%ventas_09.csv%'
        AND (carga_panel(:ses) ->> 'texto') LIKE '%Volvé a mandar solo esos%'
       THEN 'si' ELSE 'no' END);

-- Ningún documento de la sesión quedó sin contar: parseados + fallados +
-- pendientes tiene que dar el total. Es la aserción de "no se pierde nada".
SELECT _chk('todo documento está en alguna cuenta', 'si',
  CASE WHEN (SELECT count(*) FROM documentos WHERE sesion_id = :ses)
          = ((carga_resumen(:ses) ->> 'archivos')::int
           + (carga_resumen(:ses) ->> 'fallados')::int
           + (carga_resumen(:ses) ->> 'pendientes')::int)
       THEN 'si' ELSE 'no' END);

-- ===========================================================================
-- SIN NADA QUE ANALIZAR
-- ===========================================================================
UPDATE documentos SET estado = 'pendiente' WHERE sesion_id = :ses;
SELECT _chk('sin parseados no hay con qué', 'false',
  carga_hay_con_que(:ses)::text);

-- ===========================================================================
-- RESUMEN
-- ===========================================================================
\echo ''
SELECT prueba, esperado, obtenido, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS res
FROM r ORDER BY ok, prueba;

SELECT count(*) FILTER (WHERE ok) AS pasaron,
       count(*) FILTER (WHERE NOT ok) AS fallaron,
       count(*) AS total
FROM r;

ROLLBACK;
