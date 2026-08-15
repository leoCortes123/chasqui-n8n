-- Banco de regresión del router (056). Corre entero dentro de una transacción
-- que se descarta al final; cada caso además se ejecuta en un subbloque que se
-- revierte, así que un caso no contamina al siguiente y el banco NO deja rastro
-- en la base. Se puede correr contra producción sin miedo.
--
-- Para qué sirve: cualquier migración futura que toque el router se valida
-- corriéndolo ANTES y DESPUÉS y comparando. Si el cambio era un refactor, la
-- salida tiene que ser idéntica; si cambiaba comportamiento a propósito, la
-- única diferencia debe ser exactamente la buscada.
--
--   set -a; . ./.env; set +a
--   pg() { docker compose exec -T -e PGPASSWORD="$CHASQUI_DB_PASSWORD" postgres \
--            psql -U "$CHASQUI_DB_USER" -d "$CHASQUI_DB"; }
--   pg < db/pruebas/router_casos.sql > /tmp/antes.txt
--   bash bin/migrar.sh
--   pg < db/pruebas/router_casos.sql > /tmp/despues.txt
--   diff /tmp/antes.txt /tmp/despues.txt
--
-- La ÚNICA diferencia esperable es el id que imprime el `usuario_de_canal` del
-- fixture: las secuencias avanzan aunque el subbloque se revierta. Los ids y
-- tokens que aparecen dentro de las respuestas ya van enmascarados por `_norm`.
\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
BEGIN;

CREATE FUNCTION _norm(t text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    -- Los ids de secuencia avanzan aunque el subbloque se revierta, y el token
    -- del portal es aleatorio: se enmascaran para poder comparar dos corridas.
    SELECT regexp_replace(
             regexp_replace(
               regexp_replace(coalesce(t,''), '"(sesion_id|ejecucion_id|id)": *[0-9]+', '"\1": N', 'g'),
               '[A-Za-z0-9_-]{20,}', 'TOKEN', 'g'),
             '[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9:.+-]+', 'FECHA', 'g');
$$;

CREATE FUNCTION _t(p_caso text, p_evento jsonb) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_out text;
BEGIN
    BEGIN
        v_out := _norm(router_procesar_mensaje(p_evento)::text);
        RAISE EXCEPTION SQLSTATE 'ZZZZZ';          -- fuerza el rollback del subbloque
    EXCEPTION
        WHEN SQLSTATE 'ZZZZZ' THEN NULL;           -- las variables sobreviven; las tablas no
        WHEN OTHERS THEN v_out := 'ERROR ' || SQLSTATE || ': ' || SQLERRM;
    END;
    RETURN rpad(p_caso, 34) || ' => ' || v_out;
END;
$$;

CREATE FUNCTION _ev(p_texto text, p_doc boolean DEFAULT false) RETURNS jsonb LANGUAGE sql AS $$
    SELECT jsonb_build_object(
      'chat', jsonb_build_object('id', 777001),
      'from', jsonb_build_object('id', 777001, 'username', 'prueba'),
      'texto', p_texto, 'tiene_documento', p_doc);
$$;

-- ---------------------------------------------------------------------------
-- Fixture: un usuario ya visto, autorizado, con negocio.
-- ---------------------------------------------------------------------------
SELECT '--- BLOQUE A: usuario nuevo, sin autorizar ---';
SELECT _t('A1 /start',            _ev('/start'));
SELECT _t('A2 texto libre',       _ev('¿cómo está mi negocio?'));
SELECT _t('A3 mod:negocio',       _ev('mod:negocio'));
SELECT _t('A4 modayuda:negocio',  _ev('modayuda:negocio'));
SELECT _t('A5 mod inexistente',   _ev('mod:noexiste'));
SELECT _t('A6 acepto suelto',     _ev('acepto'));
SELECT _t('A7 acepto:svc',        _ev('acepto:svc:ventas_compras'));
SELECT _t('A8 svc sin autorizar', _ev('svc:ventas_compras'));
SELECT _t('A9 /salud no admin',   _ev('/salud'));

-- Ahora sí: el usuario existe y está autorizado.
SELECT usuario_de_canal('telegram', _ev(''));
UPDATE usuarios SET autorizacion_datos = true, autorizacion_fecha = now(),
                    negocio_id = (SELECT id FROM negocios ORDER BY id LIMIT 1)
WHERE telegram_user_id = 777001;

SELECT '--- BLOQUE B: autorizado, sin sesión ---';
SELECT _t('B1 /start',            _ev('/start'));
SELECT _t('B2 /comofunciona',     _ev('/comofunciona'));
SELECT _t('B3 /privacidad',       _ev('/privacidad'));
SELECT _t('B4 /plan',             _ev('/plan'));
SELECT _t('B5 /portal',           _ev('/portal'));
SELECT _t('B6 /saber vacío',      _ev('/saber'));
SELECT _t('B7 /saber algo',       _ev('/saber El domingo cierro. Siempre.'));
SELECT _t('B8 /cancelar',         _ev('/cancelar'));
SELECT _t('B9 tipo:minimercado',  _ev('tipo:minimercado'));
SELECT _t('B10 tipo inválido',    _ev('tipo:noexiste'));
SELECT _t('B11 svc:ventas',       _ev('svc:ventas_compras'));
SELECT _t('B12 svc inválido',     _ev('svc:noexiste'));
SELECT _t('B13 svc:consulta',     _ev('svc:consulta'));
SELECT _t('B14 /nueva',           _ev('/nueva'));
SELECT _t('B15 texto libre',      _ev('¿cuál es mi producto más rentable?'));
SELECT _t('B16 comando raro',     _ev('/zzz'));
SELECT _t('B17 documento',        _ev('', true));
SELECT _t('B18 /todos sin sesión',_ev('/todos'));
SELECT _t('B19 /listo sin sesión',_ev('/listo'));

SELECT '--- BLOQUE C: sesión en intake ---';
INSERT INTO sesiones (usuario_id, negocio_id, estado, paso)
SELECT id, negocio_id, 'intake', 'elegir_servicio' FROM usuarios WHERE telegram_user_id = 777001;
SELECT _t('C1 nombre del servicio', _ev('ventas'));
SELECT _t('C2 código exacto',       _ev('mercado_compras'));
SELECT _t('C3 no reconocido',       _ev('cualquier cosa'));
SELECT _t('C4 svc: en intake',      _ev('svc:ventas_compras'));
SELECT _t('C5 documento en intake', _ev('', true));
SELECT _t('C6 /cancelar',           _ev('/cancelar'));
SELECT _t('C7 /nueva',              _ev('/nueva'));
SELECT _t('C8 /start',              _ev('/start'));
UPDATE sesiones SET paso = 'otro_paso' WHERE cerrada_en IS NULL;
SELECT _t('C9 intake con paso raro', _ev('hola'));
UPDATE sesiones SET paso = 'elegir_servicio' WHERE cerrada_en IS NULL;

SELECT '--- BLOQUE D: sesión recibiendo ---';
UPDATE sesiones SET estado = 'recibiendo', paso = 'cargar_archivos',
                    servicio_codigo = 'ventas_compras' WHERE cerrada_en IS NULL;
SELECT _t('D1 texto suelto',      _ev('hola'));
SELECT _t('D2 documento',         _ev('', true));
SELECT _t('D3 svc: ya elegido',   _ev('svc:mercado_compras'));
SELECT _t('D4 /todos sin docs',   _ev('/todos'));
SELECT _t('D5 /faltan',           _ev('/faltan'));
SELECT _t('D6 /listo sin docs',   _ev('/listo'));
SELECT _t('D7 /analizar sin docs',_ev('/analizar'));
SELECT _t('D8 /cancelar',         _ev('/cancelar'));
SELECT _t('D9 /nueva',            _ev('/nueva'));
SELECT _t('D10 texto libre largo',_ev('¿cómo está mi negocio?'));

-- mercado_compras sí puede correr sin archivos si hay compras visibles (C9).
UPDATE sesiones SET servicio_codigo = 'mercado_compras' WHERE cerrada_en IS NULL;
SELECT _t('D11 mercado /listo',   _ev('/listo'));

SELECT '--- BLOQUE E: sesión procesando ---';
UPDATE sesiones SET estado = 'procesando', paso = 'ejecutando' WHERE cerrada_en IS NULL;
SELECT _t('E1 texto',             _ev('hola'));
SELECT _t('E2 /listo',            _ev('/listo'));
SELECT _t('E3 documento',         _ev('', true));
SELECT _t('E4 /cancelar',         _ev('/cancelar'));
SELECT _t('E5 /start',            _ev('/start'));

SELECT '--- BLOQUE F: admin ---';
UPDATE usuarios SET rol = 'admin' WHERE telegram_user_id = 777001;
SELECT _t('F1 /salud',            _ev('/salud'));
SELECT _t('F2 /embudo',           _ev('/embudo'));
SELECT _t('F3 /matching',         _ev('/matching'));
SELECT _t('F4 /admin',            _ev('/admin'));
-- El admin NO debe refrescar ultima_actividad de la sesión abierta.
UPDATE usuarios SET rol = 'dueno' WHERE telegram_user_id = 777001;

SELECT '--- BLOQUE G: un solo servicio de archivos ---';
UPDATE servicios SET activo = false WHERE codigo = 'mercado_compras';
UPDATE sesiones SET estado = 'expirada', cerrada_en = now() WHERE cerrada_en IS NULL;
SELECT _t('G1 documento sin sesión', _ev('', true));
SELECT _t('G2 /nueva',               _ev('/nueva'));
INSERT INTO sesiones (usuario_id, negocio_id, estado, paso)
SELECT id, negocio_id, 'intake', 'elegir_servicio' FROM usuarios WHERE telegram_user_id = 777001;
SELECT _t('G3 documento en intake',  _ev('', true));

SELECT '--- BLOQUE H: WhatsApp por el mismo router ---';
UPDATE servicios SET activo = true WHERE codigo = 'mercado_compras';
SELECT _t('H1 wa /start',
          _ev('/start') || jsonb_build_object('canal','whatsapp'));

ROLLBACK;
