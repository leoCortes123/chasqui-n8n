-- El negocio recién nacido: que exista, que opere y que no invente nada.
--
-- Los otros bancos parten de un negocio CON historia; este parte del estado en
-- el que arranca todo negocio real: cero productos, cero movimientos, cero
-- compras, cero ventas, cero proveedores, cero inventario, cero cartera, cero
-- snapshots, cero recomendaciones, cero ejecuciones.
--
-- Corre entera dentro de una transacción que se descarta: no deja rastro y se
-- puede correr contra producción.
--
--   bash bin/pruebas.sh empty_state
--
-- La regla que se está probando NO es "que no truene". Es la distinción entre
-- las dos cosas que un sistema vacío puede hacer:
--
--   * decir «todavía no tengo con qué» ......... comportamiento correcto
--   * dibujar un semáforo, una recomendación o
--     una cifra que nadie puede justificar ..... falla, aunque no lance error
--
-- Por eso casi ninguna aserción de acá dice "no hubo excepción": dicen qué
-- valor exacto tiene que salir. `salud_negocio` devolviendo NULL es el
-- resultado esperado, y un 0 en su lugar sería el fallo.
--
-- Lo que NO cubre: el transporte (descarga de Telegram, nodos de n8n) y la
-- llamada al LLM. La transición de vacío a con-datos por las rutas reales de
-- ingesta la corre `bin/prueba_ciclo_vida.py`.
\set ON_ERROR_STOP on
\pset format aligned
BEGIN;

CREATE TEMP TABLE r(prueba text, esperado text, obtenido text, ok boolean);
CREATE FUNCTION _chk(p text, esp text, obt text) RETURNS void LANGUAGE sql AS $$
    INSERT INTO r VALUES (p, esp, obt, esp IS NOT DISTINCT FROM obt);
$$;

-- Para la parte de "que ninguna operación reviente": ejecuta y guarda el
-- SQLSTATE si algo se cae. Una excepción en un negocio vacío es la falla más
-- cara de todas, porque le pasa al usuario en su primer minuto.
CREATE FUNCTION _sin_error(p text, sql text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
    EXECUTE 'SELECT (' || sql || ')::text' INTO v;
    PERFORM _chk(p, 'sin error', 'sin error');
EXCEPTION WHEN OTHERS THEN
    PERFORM _chk(p, 'sin error', SQLSTATE || ' ' || SQLERRM);
END; $$;

-- ===========================================================================
-- Fixture 1: el negocio VECINO, con datos. Existe solo para que el aislamiento
-- se pueda probar de verdad: si el negocio vacío se contamina, tiene de dónde.
-- ===========================================================================
INSERT INTO negocios (nombre, plan) VALUES ('PRUEBA vecino con datos', 'pro')
RETURNING id AS vecino \gset
INSERT INTO usuarios (negocio_id, telegram_user_id, telegram_chat_id, rol,
                      autorizacion_datos, autorizacion_fecha)
VALUES (:vecino, 990998, 990998, 'dueno', true, now());
INSERT INTO productos (negocio_id, nombre_canonico, unidad)
VALUES (:vecino, 'PRODUCTO DEL VECINO', 'und') RETURNING id AS prod_v \gset
INSERT INTO movimientos (negocio_id, tipo, fecha, producto_id, cantidad,
                         valor_unitario, valor_total, raw)
SELECT :vecino, 'compra'::tipo_movimiento, current_date - 40 + g*10, :prod_v,
       20, 9000, 180000, jsonb_build_object('proveedor','Proveedor del vecino')
FROM generate_series(0,3) g
UNION ALL
SELECT :vecino, 'venta'::tipo_movimiento, current_date - 35 + g*8, :prod_v,
       8, 10000, 80000, '{}'::jsonb
FROM generate_series(0,4) g;
SELECT recomendaciones_registrar(:vecino);
SELECT snapshot_tomar(:vecino, 'manual');

-- ===========================================================================
-- 1. Alta: el negocio nace por la ruta real, no por un INSERT
-- ===========================================================================
-- La ruta real es un update de Telegram de alguien que no existe todavía. El
-- usuario, la identidad y el negocio los crea `usuario_de_canal` (050); no hay
-- pantalla de registro, y por eso el alta se prueba acá y no en un fixture.
CREATE FUNCTION _ev(t text) RETURNS jsonb LANGUAGE sql AS $$
    SELECT jsonb_build_object(
      'from', jsonb_build_object('id','990999','username','recien_llegado'),
      'chat', jsonb_build_object('id','990999'), 'texto', t);
$$;

SELECT _chk('alta/1 /start contesta la bienvenida', 'sistema.bienvenida',
  (router_procesar_mensaje(_ev('/start')) #>> '{respuestas,0,plantilla}'));

SELECT id AS usr, negocio_id AS neg FROM usuarios WHERE telegram_user_id = 990999 \gset

SELECT _chk('alta/2 el negocio existe', 'si',
  CASE WHEN :neg IS NOT NULL THEN 'si' ELSE 'no' END);
SELECT _chk('alta/3 nace en plan free', 'free',
  (SELECT plan FROM negocios WHERE id = :neg));
SELECT _chk('alta/4 nace con cupo, no bloqueado', 'si',
  (SELECT CASE WHEN cupo_tokens_mes > 0 THEN 'si' ELSE 'no' END
     FROM negocios WHERE id = :neg));
-- El NIT NO es obligatorio para operar: solo hace falta para que la cartera
-- pueda distinguir una factura emitida de una recibida (038). Que nazca sin él
-- es correcto; lo que no puede es impedir el resto.
SELECT _chk('alta/5 nace sin NIT y eso no lo bloquea', 'si',
  (SELECT CASE WHEN nit IS NULL THEN 'si' ELSE 'no' END
     FROM negocios WHERE id = :neg));
SELECT _chk('alta/6 nace sin autorización de datos', 'false',
  (SELECT autorizacion_datos::text FROM usuarios WHERE id = :usr));
SELECT _chk('alta/7 la identidad del canal quedó registrada', '1',
  (SELECT count(*)::text FROM identidades
    WHERE canal = 'telegram' AND id_externo = '990999'));

-- Cero de todo. Es la premisa de este banco; si esto falla, lo demás no mide
-- lo que dice medir.
SELECT _chk('vacío/1 cero productos',       '0', (SELECT count(*)::text FROM productos          WHERE negocio_id = :neg));
SELECT _chk('vacío/2 cero movimientos',     '0', (SELECT count(*)::text FROM movimientos        WHERE negocio_id = :neg));
SELECT _chk('vacío/3 cero documentos',      '0', (SELECT count(*)::text FROM documentos         WHERE negocio_id = :neg));
SELECT _chk('vacío/4 cero terceros',        '0', (SELECT count(*)::text FROM terceros           WHERE negocio_id = :neg));
SELECT _chk('vacío/5 cero facturas',        '0', (SELECT count(*)::text FROM facturas           WHERE negocio_id = :neg));
SELECT _chk('vacío/6 cero conteos',         '0', (SELECT count(*)::text FROM conteos_inventario WHERE negocio_id = :neg));
SELECT _chk('vacío/7 cero snapshots',       '0', (SELECT count(*)::text FROM snapshots_negocio  WHERE negocio_id = :neg));
SELECT _chk('vacío/8 cero recomendaciones', '0', (SELECT count(*)::text FROM recomendaciones    WHERE negocio_id = :neg));
SELECT _chk('vacío/9 cero ejecuciones',     '0', (SELECT count(*)::text FROM ejecuciones        WHERE negocio_id = :neg));
SELECT _chk('vacío/10 cero alias',          '0', (SELECT count(*)::text FROM alias              WHERE negocio_id = :neg));

-- ===========================================================================
-- 2. Salud: sin datos NO se dibuja semáforo
-- ===========================================================================
-- Un índice de 0 sería una nota de examen que nadie presentó, y un 100 sería
-- peor. NULL es el único valor honesto, y `hallazgos_generar` lo propaga.
SELECT _chk('salud/1 sin datos no hay índice', '<NULL>',
  coalesce(salud_negocio(:neg)::text, '<NULL>'));
SELECT _chk('salud/2 el informe tampoco lo inventa', '<NULL>',
  coalesce(hallazgos_generar(:neg) #>> '{salud}', '<NULL>'));
SELECT _chk('salud/3 el bloque de salud del informe queda vacío', '<NULL>',
  coalesce(informe_salud_bloque(salud_negocio(:neg), 'ventas_compras'), '<NULL>'));

-- ===========================================================================
-- 3. Análisis sin datos: se puede pedir, y no dice nada que no sepa
-- ===========================================================================
SELECT _chk('analisis/1 el periodo va en cero, no en NULL falso', '0 0',
  (SELECT format('%s %s',
     hallazgos_generar(:neg) #>> '{periodo,movimientos_venta}',
     hallazgos_generar(:neg) #>> '{periodo,movimientos_compra}')));
SELECT _chk('analisis/2 sin fechas no se inventa un rango', '<NULL>',
  coalesce(hallazgos_generar(:neg) #>> '{periodo,desde}', '<NULL>'));
SELECT _chk('analisis/3 cero productos en el resumen', '0',
  (hallazgos_generar(:neg) #>> '{resumen,productos}'));
SELECT _chk('analisis/4 sin margen promedio inventado', '<NULL>',
  coalesce(hallazgos_generar(:neg) #>> '{resumen,margen_promedio_pct}', '<NULL>'));
SELECT _chk('analisis/5 ninguna lista de hallazgos trae elementos', '0 0 0 0',
  (SELECT format('%s %s %s %s',
     jsonb_array_length(hallazgos_generar(:neg) -> 'margen_bajo'),
     jsonb_array_length(hallazgos_generar(:neg) -> 'deriva_costo'),
     jsonb_array_length(hallazgos_generar(:neg) -> 'baja_cobertura'),
     jsonb_array_length(hallazgos_generar(:neg) -> 'pareto'))));
-- Sin snapshot previo no hay comparativo: es lo que evita el "creciste un 0%".
SELECT _chk('analisis/6 sin historia no hay comparativo', '<NULL>',
  coalesce(hallazgos_comparativo(:neg)::text, '<NULL>'));
SELECT _chk('analisis/7 el servicio de compras también sale limpio', '0 0',
  (SELECT format('%s %s',
     hallazgos_compras(:neg) #>> '{resumen,proveedores}',
     hallazgos_compras(:neg) #>> '{resumen,gasto_total}')));

-- El motor prepara la corrida igual (el cupo y el prompt existen), pero lo que
-- le pasa al modelo no contiene un solo número que no sea cero.
INSERT INTO ejecuciones (negocio_id, servicio_codigo, estado)
VALUES (:neg, 'ventas_compras', 'preparando') RETURNING id AS eje \gset
SELECT _chk('analisis/8 ejecucion_preparar no se bloquea ni falla', 'false <NULL>',
  (SELECT format('%s %s',
     ejecucion_preparar(:eje) ->> 'bloqueado',
     coalesce(ejecucion_preparar(:eje) ->> 'error', '<NULL>'))));
SELECT _chk('analisis/9 y valida su propio texto sin cifras', 'true',
  (validar_cifras('Todavía no tengo movimientos cargados.',
                  hallazgos_generar(:neg)) ->> 'ok'));

-- ===========================================================================
-- 4. Recomendaciones: cero, y sobre todo cero registradas
-- ===========================================================================
-- `recomendaciones_negocio(neg, true)` es el modo registro: devuelve TODO lo
-- detectado, sin filtrar por lo ya mostrado. Si algo saliera acá, saldría
-- también en la primera alerta que reciba el usuario.
SELECT _chk('reco/1 no se detecta nada', '0',
  jsonb_array_length(recomendaciones_negocio(:neg, true))::text);
SELECT _chk('reco/2 registrar no crea filas', '0 0',
  (SELECT format('%s %s',
     recomendaciones_registrar(:neg) ->> 'nuevas',
     (SELECT count(*) FROM recomendaciones WHERE negocio_id = :neg))));
SELECT _chk('reco/3 medir no encuentra qué medir', '0 0 0',
  (SELECT format('%s %s %s',
     recomendaciones_medir(:neg) ->> 'positivo',
     recomendaciones_medir(:neg) ->> 'negativo',
     recomendaciones_medir(:neg) ->> 'neutro')));
SELECT _chk('reco/4 el pedido sugerido no pide nada', '0 0',
  (SELECT format('%s %s',
     pedido_sugerido(:neg) ->> 'productos',
     pedido_sugerido(:neg) ->> 'total')));
-- El informe seco es lo que se entrega cuando el LLM no narra. Con cero
-- hallazgos no puede quedar una viñeta suelta.
-- Sin recomendaciones la estructura seca ni siquiera trae la clave `hallazgos`
-- (solo la trae la rama que las tiene), así que se comprueba el efecto: cero
-- viñetas por los dos caminos posibles.
SELECT _chk('reco/5 el informe seco no lista hallazgos', '0 0',
  (SELECT format('%s %s',
     coalesce(jsonb_array_length(informe_estructura_seca(hallazgos_generar(:neg), 'ventas_compras') -> 'hallazgos'), 0),
     coalesce(jsonb_array_length(informe_estructura_seca(hallazgos_generar(:neg), 'ventas_compras') -> 'secciones'), 0))));

-- ===========================================================================
-- 5. Alertas: un negocio vacío no es alertable
-- ===========================================================================
-- Es la prueba de que la compuerta está ANTES de las reglas y no después: el
-- negocio vacío ni siquiera entra al recorrido.
SELECT _chk('alerta/1 no aparece entre los alertables', '0',
  (SELECT count(*)::text FROM v_negocios_alertables WHERE negocio_id = :neg));
SELECT _chk('alerta/2 ni entre los del informe periódico', '0',
  (SELECT count(*)::text FROM v_negocios_informe_periodico WHERE negocio_id = :neg));
SELECT _chk('alerta/3 una corrida real no le manda nada', '0',
  (SELECT count(*)::text
     FROM jsonb_array_elements(alertas_evaluar() -> 'notificaciones') e
    WHERE (e ->> 'chat_id')::bigint = 990999));
SELECT _chk('alerta/4 ni el informe periódico le abre ejecución', '0',
  (SELECT count(*)::text
     FROM jsonb_array_elements(informes_periodicos_disparar() -> 'ejecuciones') e
    WHERE (e ->> 'negocio_id')::bigint = :neg));

-- ===========================================================================
-- 6. Memoria: sin movimientos no se fotografía la nada
-- ===========================================================================
-- Un snapshot vacío haría creer a la comparación del mes siguiente que hubo un
-- periodo medido en el que todo valía cero, y el negocio "caería" desde ahí.
SELECT _chk('memoria/1 snapshot_tomar devuelve NULL', '<NULL>',
  coalesce(snapshot_tomar(:neg, 'manual')::text, '<NULL>'));
SELECT _chk('memoria/2 y no dejó fila', '0',
  (SELECT count(*)::text FROM snapshots_negocio WHERE negocio_id = :neg));
SELECT _chk('memoria/3 no hay snapshot anterior', '<NULL>',
  coalesce(snapshot_anterior(:neg)::text, '<NULL>'));
SELECT _chk('memoria/4 el perfil no cuenta acciones ni resultados', '0 0',
  (SELECT format('%s %s',
     perfil_negocio(:neg) #>> '{acciones,cerradas_total}',
     perfil_negocio(:neg) #>> '{resultados,positivo}')));

-- ===========================================================================
-- 7. Inventario y cartera vacíos
-- ===========================================================================
SELECT _chk('inventario/1 sin stock que rotar', '0',
  (SELECT count(*)::text FROM v_rotacion_producto WHERE negocio_id = :neg));
SELECT _chk('inventario/2 sin balance de unidades', '0',
  (SELECT count(*)::text FROM v_balance_unidades WHERE negocio_id = :neg));
SELECT _chk('cartera/1 sin edades de cartera', '0',
  (SELECT count(*)::text FROM v_cartera_edades WHERE negocio_id = :neg));
SELECT _chk('cartera/2 refacturar no truena sin facturas', 'sin error', 'sin error');
SELECT _sin_error('cartera/2 refacturar no truena sin facturas',
                  format('cartera_refacturar(%s)', :neg));
-- La liquidez es la sexta nota de salud (069): sin una sola factura a crédito
-- tiene que faltar, no valer cero. Un negocio que vende de contado no puede
-- ver bajar su índice por una nota que no le aplica.
SELECT _chk('cartera/3 la liquidez no entra al índice', '<NULL>',
  coalesce(salud_negocio(:neg) #>> '{liquidez}', '<NULL>'));

-- ===========================================================================
-- 8. Router: los caminos que un negocio vacío puede tomar
-- ===========================================================================
SELECT _chk('router/1 /comofunciona se lee sin autorizar', 'sistema.como_funciona',
  (router_procesar_mensaje(_ev('/comofunciona')) #>> '{respuestas,0,plantilla}'));
SELECT _chk('router/2 /privacidad también', 'sistema.privacidad',
  (router_procesar_mensaje(_ev('/privacidad')) #>> '{respuestas,0,plantilla}'));
SELECT _chk('router/3 sin autorizar, se pide el consentimiento', 'sistema.consentimiento',
  (router_procesar_mensaje(_ev('¿cómo voy?')) #>> '{respuestas,0,plantilla}'));
-- En dos sentencias a propósito: dentro de una sola, el SELECT sobre `usuarios`
-- lee el snapshot del comienzo y no vería el UPDATE que hace el router.
SELECT router_procesar_mensaje(_ev('acepto:/start'));
SELECT _chk('router/4 al aceptar queda la marca', 'true',
  (SELECT autorizacion_datos::text FROM usuarios WHERE id = :usr));
SELECT _chk('router/5 /plan responde con cupo real', 'plan.estado free',
  (SELECT format('%s %s',
     router_procesar_mensaje(_ev('/plan')) #>> '{respuestas,0,plantilla}',
     router_procesar_mensaje(_ev('/plan')) #>> '{respuestas,0,vars,plan}')));
-- /portal depende de una precondición de ENTORNO, no de producto: la URL
-- pública la escribe bin/registrar-webhook.sh cuando levanta el túnel. El
-- baseline la instala vacía a propósito (v0 no puede saber en qué dominio va a
-- vivir), así que la prueba la fija ella misma y comprueba los DOS caminos.
-- Antes daba por sentada la URL de la máquina donde se corría.
UPDATE parametros SET valor = to_jsonb('https://ejemplo.test'::text)
 WHERE clave = 'portal_url_base' AND negocio_id IS NULL;
SELECT _chk('router/6 con URL configurada, /portal entrega enlace', 'portal.enlace',
  (router_procesar_mensaje(_ev('/portal')) #>> '{respuestas,0,plantilla}'));
UPDATE parametros SET valor = '""'::jsonb
 WHERE clave = 'portal_url_base' AND negocio_id IS NULL;
SELECT _chk('router/6b sin URL configurada, /portal lo dice en vez de mandar un enlace roto',
  'portal.sin_url',
  (router_procesar_mensaje(_ev('/portal')) #>> '{respuestas,0,plantilla}'));
-- La compuerta que importa: una pregunta sobre números que no existen no
-- arranca una ejecución (no gasta tokens) y avisa por qué.
SELECT _chk('router/7 una pregunta sin números avisa que no hay datos', 'consulta.sin_datos',
  (router_procesar_mensaje(_ev('¿cuánto vendí este mes?')) #>> '{respuestas,0,plantilla}'));
SELECT _chk('router/8 y no abrió ninguna ejecución de consulta', '0',
  (SELECT count(*)::text FROM ejecuciones
    WHERE negocio_id = :neg AND servicio_codigo = 'consulta'));
-- Pero la pregunta queda anotada: es la señal de qué le falta a la KB.
SELECT _chk('router/9 la pregunta sin respuesta queda pendiente', '1',
  (SELECT count(*)::text FROM conocimiento_pendiente WHERE negocio_id = :neg));
-- Todavía sin sesión abierta: cancelar la nada tiene que ser inofensivo.
SELECT _chk('router/10 /cancelar sin sesión no rompe', 'sistema.sin_sesion',
  (router_procesar_mensaje(_ev('/cancelar')) #>> '{respuestas,0,plantilla}'));
SELECT _chk('router/11 /nueva ofrece los servicios', 'sistema.elegir_servicio',
  (router_procesar_mensaje(_ev('/nueva')) #>> '{respuestas,0,plantilla}'));
-- El servicio se elige y la conversación queda esperando archivos; de paso
-- pregunta la naturaleza del negocio, que un negocio nuevo tampoco tiene.
SELECT router_procesar_mensaje(_ev('svc:ventas_compras'));
SELECT _chk('router/12 elegir servicio deja la sesión recibiendo', 'recibiendo',
  (SELECT estado::text FROM sesiones
    WHERE usuario_id = :usr AND cerrada_en IS NULL ORDER BY id DESC LIMIT 1));
SELECT _chk('router/13 /listo sin archivos no ejecuta nada', 'sistema.sin_documentos',
  (router_procesar_mensaje(_ev('/listo')) #>> '{respuestas,0,plantilla}'));
SELECT _chk('router/14 /analizar tampoco', 'sistema.sin_documentos',
  (router_procesar_mensaje(_ev('/analizar')) #>> '{respuestas,0,plantilla}'));
-- La única ejecución que existe es la que abrió este banco a mano en
-- `analisis/8`; el router no abrió ninguna.
SELECT _chk('router/15 el router no abrió ninguna ejecución', '0',
  (SELECT count(*)::text FROM ejecuciones
    WHERE negocio_id = :neg AND servicio_codigo = 'ventas_compras' AND id <> :eje));
SELECT _chk('router/16 /cancelar cierra la sesión abierta', 'sesion.cancelada',
  (router_procesar_mensaje(_ev('/cancelar')) #>> '{respuestas,0,plantilla}'));
SELECT _chk('router/17 una acción sobre recomendación inexistente se rechaza',
  'recomendacion.no_encontrada',
  (router_procesar_mensaje(_ev('rec:hice:999999')) #>> '{respuestas,0,plantilla}'));
-- Y con un dato de KB cargado a mano, la misma pregunta ya se puede contestar
-- sin un solo movimiento: ese es el otro camino para salir del estado vacío.
SELECT _chk('router/18 /saber guarda conocimiento', 'conocimiento.guardado',
  (router_procesar_mensaje(_ev('/saber el local abre a las 8 de la mañana'))
     #>> '{respuestas,0,plantilla}'));
SELECT _chk('router/19 con KB la consulta ya arranca', 'consulta.pensando',
  (router_procesar_mensaje(_ev('¿a qué hora abre el local?'))
     #>> '{respuestas,0,plantilla}'));

-- ===========================================================================
-- 9. Portal: todas las pantallas abren vacías, ninguna falla
-- ===========================================================================
SELECT set_config('request.jwt.claims',
  jsonb_build_object('role','portal_usuario','usuario_id',:usr,'negocio_id',:neg,
                     'exp', extract(epoch FROM now() + interval '1 hour')::bigint)::text,
  true);

SELECT _chk('portal/1 la sesión resuelve el negocio', :'neg', portal_negocio()::text);
SELECT _chk('portal/2 productos',      '[]', portal_productos()::text);
SELECT _chk('portal/3 movimientos',    '[]', portal_movimientos(NULL, 20)::text);
SELECT _chk('portal/4 snapshots',      '[]', portal_snapshots(10)::text);
SELECT _chk('portal/5 conteos',        '[]', portal_conteos(10)::text);
SELECT _chk('portal/6 documentos',     '[]', portal_documentos(10)::text);
SELECT _chk('portal/7 cotizaciones',   '[]', portal_cotizaciones(10)::text);
SELECT _chk('portal/8 recomendaciones', '0 0',
  (SELECT format('%s %s',
     jsonb_array_length(portal_recomendaciones(10) -> 'vigentes'),
     jsonb_array_length(portal_recomendaciones(10) -> 'cerradas'))));
SELECT _chk('portal/9 cartera en ceros, no en NULL', '0 0',
  (SELECT format('%s %s',
     portal_cartera() #>> '{resumen,por_cobrar}',
     portal_cartera() #>> '{resumen,vencido_cobrar}')));
SELECT _chk('portal/10 resumen de movimientos en ceros', '0 0',
  (SELECT format('%s %s',
     portal_movimientos_resumen() #>> '{mes_actual,ventas}',
     portal_movimientos_resumen() #>> '{mes_actual,movimientos}')));
SELECT _chk('portal/11 alias pendientes', '0',
  jsonb_array_length(portal_alias_pendientes(10) -> 'pendientes')::text);
SELECT _sin_error('portal/12 perfil abre', 'portal_perfil()');
SELECT _sin_error('portal/13 pedido abre', 'portal_pedido()');
SELECT _sin_error('portal/14 informes abre', 'portal_informes(10)');
SELECT _sin_error('portal/15 pendientes abre', 'portal_pendientes()');

SELECT set_config('request.jwt.claims', NULL, true);

-- ===========================================================================
-- 10. Aislamiento: el vecino tiene datos; el vacío no ve ni uno
-- ===========================================================================
SELECT _chk('aisla/1 el vecino sí tiene movimientos', 'si',
  (SELECT CASE WHEN count(*) > 0 THEN 'si' ELSE 'no' END
     FROM movimientos WHERE negocio_id = :vecino));
SELECT _chk('aisla/2 el vecino sí tiene recomendaciones', 'si',
  (SELECT CASE WHEN count(*) > 0 THEN 'si' ELSE 'no' END
     FROM recomendaciones WHERE negocio_id = :vecino));
SELECT _chk('aisla/3 el vecino sí tiene snapshot', 'si',
  (SELECT CASE WHEN count(*) > 0 THEN 'si' ELSE 'no' END
     FROM snapshots_negocio WHERE negocio_id = :vecino));
SELECT _chk('aisla/4 y el vacío sigue sin ver nada de eso', '0 0 0 0',
  (SELECT format('%s %s %s %s',
     (SELECT count(*) FROM mov_visibles      WHERE negocio_id = :neg),
     (SELECT count(*) FROM v_margen_producto WHERE negocio_id = :neg),
     (SELECT count(*) FROM recomendaciones   WHERE negocio_id = :neg),
     (SELECT count(*) FROM snapshots_negocio WHERE negocio_id = :neg))));
SELECT _chk('aisla/5 su salud sigue siendo NULL con el vecino cargado', '<NULL>',
  coalesce(salud_negocio(:neg)::text, '<NULL>'));
SELECT _chk('aisla/6 y el perfil no le presta el periodo del vecino', '<NULL>',
  coalesce(perfil_negocio(:neg) #>> '{periodo,desde}', '<NULL>'));

-- ===========================================================================
-- 11. Barrido: ninguna operación del catálogo lanza excepción en vacío
-- ===========================================================================
-- Las aserciones de arriba miran el SENTIDO de cada respuesta. Esto mira lo
-- otro: que ninguna función que el sistema puede llamar sobre un negocio nuevo
-- —división por cero, NULL sin coalesce, índice de un array vacío— se caiga.
SELECT _sin_error('barrido/salud_negocio',        format('salud_negocio(%s)', :neg));
SELECT _sin_error('barrido/hallazgos_generar',    format('hallazgos_generar(%s)', :neg));
SELECT _sin_error('barrido/hallazgos_compras',    format('hallazgos_compras(%s)', :neg));
-- Y las mismas por la firma que usa producción. `ejecucion_preparar` despacha
-- SIEMPRE `%I(bigint, jsonb)` leyendo `servicios.funcion_hallazgos`, así que las
-- llamadas de un argumento de arriba prueban una función que el runtime nunca
-- invoca. Para `hallazgos_generar` da igual —su envoltorio delega y ya—, pero el
-- de `hallazgos_compras` agrega salud, recomendaciones y tipo_negocio, que es
-- justo lo que ve el prompt de mercado_compras y no estaba cubierto por nada.
SELECT _sin_error('barrido/hallazgos_generar despachado',
  format($$hallazgos_generar(%s, '{}'::jsonb)$$, :neg));
SELECT _sin_error('barrido/hallazgos_compras despachado',
  format($$hallazgos_compras(%s, '{}'::jsonb)$$, :neg));
SELECT _sin_error('barrido/contexto_negocio',
  format($$contexto_negocio_recuperar(%s, '{"pregunta":"¿cuánto vendí?"}'::jsonb)$$, :neg));
SELECT _sin_error('barrido/perfil_negocio',       format('perfil_negocio(%s)', :neg));
SELECT _sin_error('barrido/pedido_sugerido',      format('pedido_sugerido(%s)', :neg));
SELECT _sin_error('barrido/alias_pendientes',     format('alias_pendientes(%s)', :neg));
SELECT _sin_error('barrido/snapshot_umbrales',    format('snapshot_umbrales(%s)', :neg));
SELECT _sin_error('barrido/intencion_resolver',
  format($$intencion_resolver(%s, '¿cuánto vendí este mes?')$$, :neg));
SELECT _sin_error('barrido/intencion_agregados',
  format($$intencion_agregados(%s,'ventas',current_date - 30,current_date,NULL,NULL)$$, :neg));
SELECT _sin_error('barrido/conocimiento_buscar',  format($$conocimiento_buscar(%s,'precio')$$, :neg));
SELECT _sin_error('barrido/informe_render seco',
  format($$informe_render(informe_estructura_seca(hallazgos_generar(%1$s),'ventas_compras'),
                          hallazgos_generar(%1$s),'ventas_compras')$$, :neg));
SELECT _sin_error('barrido/mantenimiento_ciclo',  'mantenimiento_ciclo()');
SELECT _sin_error('barrido/v_calidad_matching',
  format('(SELECT count(*) FROM v_calidad_matching WHERE negocio_id = %s)', :neg));
SELECT _sin_error('barrido/v_deriva_costo',
  format('(SELECT count(*) FROM v_deriva_costo WHERE negocio_id = %s)', :neg));
SELECT _sin_error('barrido/v_pareto_utilidad',
  format('(SELECT count(*) FROM v_pareto_utilidad WHERE negocio_id = %s)', :neg));
SELECT _sin_error('barrido/v_conocimiento_cobertura',
  format('(SELECT count(*) FROM v_conocimiento_cobertura WHERE negocio_id = %s)', :neg));

-- ===========================================================================
-- Resultado
-- ===========================================================================
SELECT prueba, esperado, obtenido, CASE WHEN ok THEN 'ok' ELSE 'FALLA' END AS r
FROM r ORDER BY ok, prueba;

SELECT count(*) FILTER (WHERE ok) AS pasaron,
       count(*) FILTER (WHERE NOT ok) AS fallaron
FROM r;

ROLLBACK;
