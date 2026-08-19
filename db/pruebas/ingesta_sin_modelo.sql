-- Banco de la 073: la ingesta reconoce formatos sin gastar una sola llamada.
--
-- Los casos centrales usan las cabeceras REALES de la segunda prueba de
-- usuario, no cabeceras de laboratorio:
--
--   ventas_detalle_2026-*.csv  ->  Fecha, Producto, Categoria, Cantidad,
--                                  Valor_Unitario, Total_Linea, Codigo_Barras, Unidad
--   cierre_caja_2026-*.csv     ->  Fecha, Total_Ventas, Nro_Transacciones
--
-- El segundo es el que el modelo aprendió mal y produjo el doble conteo de
-- $288 millones. Acá es una aserción.
--
-- Corre entero dentro de una transacción que se descarta: no deja rastro y se
-- puede correr contra producción.
--
--   set -a; . ./.env; set +a
--   docker compose exec -T -e PGPASSWORD="$CHASQUI_DB_PASSWORD" postgres \
--     psql -U "$CHASQUI_DB_USER" -d "$CHASQUI_DB" < db/pruebas/ingesta_sin_modelo.sql
\set ON_ERROR_STOP on
\pset format aligned
BEGIN;

CREATE TEMP TABLE r(prueba text, esperado text, obtenido text, ok boolean);
CREATE FUNCTION _chk(p text, esp text, obt text) RETURNS void LANGUAGE sql AS $$
    INSERT INTO r VALUES (p, esp, obt, esp IS NOT DISTINCT FROM obt);
$$;

-- ===========================================================================
-- Fixture
-- ===========================================================================
INSERT INTO negocios (nombre, plan) VALUES ('PRUEBA ingesta', 'pro')
RETURNING id AS neg \gset
INSERT INTO usuarios (negocio_id, telegram_user_id, telegram_chat_id, rol,
                      autorizacion_datos, autorizacion_fecha)
VALUES (:neg, 999601, 999601, 'dueno', true, now()) RETURNING id AS usr \gset
INSERT INTO sesiones (usuario_id, negocio_id, servicio_codigo, estado, paso)
VALUES (:usr, :neg, 'ventas_compras', 'recibiendo', 'cargar_archivos')
RETURNING id AS ses \gset

-- Las huellas reales ya están aprendidas en producción. Para que este banco
-- pruebe el camino de "huella nueva" se las esconde: se desactivan solo las
-- filas inferidas, dentro de la transacción que se descarta.
UPDATE formatos_documento SET activo = false WHERE clase = 'tabular' AND origen = 'inferido';

CREATE FUNCTION _doc(p_nombre text, p_hash bytea) RETURNS bigint LANGUAGE sql AS $$
    INSERT INTO documentos (sesion_id, negocio_id, nombre_archivo, mime, hash,
                            contenido, tamano, estado)
    VALUES ((SELECT max(id) FROM sesiones), (SELECT max(id) FROM negocios),
            p_nombre, 'text/csv', p_hash, p_hash, 1, 'pendiente')
    RETURNING id;
$$;

-- ===========================================================================
-- EL DICCIONARIO RESUELVE LAS CABECERAS REALES
-- ===========================================================================
-- Las ocho columnas del archivo de ventas, sin modelo. Si esto falla, cada
-- huella nueva vuelve a costar una llamada.
SELECT _chk('resolver/1 ventas_detalle: las 8 columnas',
  '{"fecha": "Fecha", "codigo": "Codigo_Barras", "unidad": "Unidad", "cantidad": "Cantidad", "producto": "Producto", "categoria": "Categoria", "valor_total": "Total_Linea", "valor_unitario": "Valor_Unitario"}',
  ingesta_resolver_columnas(ARRAY['Fecha','Producto','Categoria','Cantidad',
    'Valor_Unitario','Total_Linea','Codigo_Barras','Unidad'])::text);

-- Total_Linea NO puede llevarse valor_unitario ni al revés: cruzarlas invierte
-- todos los márgenes del informe.
SELECT _chk('resolver/2 Total_Linea es el total', 'Total_Linea',
  ingesta_resolver_columnas(ARRAY['Valor_Unitario','Total_Linea']) ->> 'valor_total');
SELECT _chk('resolver/3 Valor_Unitario es el unitario', 'Valor_Unitario',
  ingesta_resolver_columnas(ARRAY['Valor_Unitario','Total_Linea']) ->> 'valor_unitario');

-- "Unidades" es cuántas; "Unidad" es de qué tipo. Una sola pasada de regex las
-- confunde, y confundirlas mete la unidad de medida en la cantidad.
SELECT _chk('resolver/4 Unidades es cantidad', 'Unidades',
  ingesta_resolver_columnas(ARRAY['Fecha','Unidad','Unidades','Total']) ->> 'cantidad');
SELECT _chk('resolver/5 Unidad es unidad de medida', 'Unidad',
  ingesta_resolver_columnas(ARRAY['Fecha','Unidad','Unidades','Total']) ->> 'unidad');

-- Una columna sirve a UNA clave: sin esto "Total" quedaría en dos lugares.
SELECT _chk('resolver/6 ninguna columna se usa dos veces', '0',
  (SELECT count(*)::text FROM (
     SELECT value FROM jsonb_each_text(
       ingesta_resolver_columnas(ARRAY['Fecha','Producto','Total','Cantidad']))
     GROUP BY value HAVING count(*) > 1) d));

-- Otro POS, otras palabras, mismo resultado.
SELECT _chk('resolver/7 sinónimos de otro POS', 'si',
  CASE WHEN ingesta_resolver_columnas(ARRAY['FEC_VENTA','DESCRIPCION','CANT','PRECIO_UNIT','IMPORTE'])
         = '{"fecha":"FEC_VENTA","producto":"DESCRIPCION","cantidad":"CANT","valor_unitario":"PRECIO_UNIT","valor_total":"IMPORTE"}'::jsonb
       THEN 'si' ELSE 'no' END);

-- Cabeceras truncadas a 10 caracteres, que es lo que hacen los POS viejos.
-- VAL_UNIT vs VAL_TOTAL se separan por prioridad, no por suerte, y IMP_IVA no
-- puede caer en valor_total: un impuesto sumado a las ventas las infla.
SELECT _chk('resolver/8 cabeceras abreviadas', 'si',
  CASE WHEN ingesta_resolver_columnas(ARRAY['F_MOV','ART_DESC','CANT','VAL_UNIT','VAL_TOTAL','IMP_IVA'])
         = '{"fecha":"F_MOV","producto":"ART_DESC","cantidad":"CANT","valor_unitario":"VAL_UNIT","valor_total":"VAL_TOTAL","impuesto":"IMP_IVA"}'::jsonb
       THEN 'si' ELSE 'no' END);

-- ===========================================================================
-- FORMATO DE FECHA: la ambigüedad se resuelve mirando, no adivinando
-- ===========================================================================
SELECT _chk('fecha/1 ISO', 'YYYY-MM-DD',
  ingesta_inferir_formato_fecha('[{"F":"2026-03-01"},{"F":"2026-04-15"}]'::jsonb, 'F'));
-- Un día 25 no puede ser un mes: es DD/MM sin discusión.
SELECT _chk('fecha/2 un componente > 12 decide', 'DD/MM/YYYY',
  ingesta_inferir_formato_fecha('[{"F":"03/04/2026"},{"F":"25/04/2026"}]'::jsonb, 'F'));
SELECT _chk('fecha/3 al revés también decide', 'MM/DD/YYYY',
  ingesta_inferir_formato_fecha('[{"F":"04/25/2026"}]'::jsonb, 'F'));
-- Genuinamente ambiguo: comercio latinoamericano, DD/MM. Es la misma
-- convención que declaraba el prompt.
SELECT _chk('fecha/4 ambiguo cae a latino', 'DD/MM/YYYY',
  ingesta_inferir_formato_fecha('[{"F":"03/04/2026"}]'::jsonb, 'F'));
SELECT _chk('fecha/5 con guiones respeta el separador', 'DD-MM-YYYY',
  ingesta_inferir_formato_fecha('[{"F":"25-04-2026"}]'::jsonb, 'F'));
-- Serial de Excel: NULL y que lo resuelva ingesta_fecha, que ya sabe.
SELECT _chk('fecha/6 serial de Excel -> sin formato', NULL,
  ingesta_inferir_formato_fecha('[{"F":"46112"}]'::jsonb, 'F'));

-- Y el formato que sale de acá tiene que servirle de verdad a ingesta_fecha:
-- inferir un patrón que después no parsea no arregla nada.
SELECT _chk('fecha/7 el patrón inferido parsea', '2026-04-25',
  ingesta_fecha('"25/04/2026"'::jsonb,
    ingesta_inferir_formato_fecha('[{"F":"25/04/2026"}]'::jsonb, 'F'))::text);

-- ===========================================================================
-- SEPARADORES: se leen de la muestra
-- ===========================================================================
SELECT _chk('num/1 1.234,56 es latino', ',',
  ingesta_inferir_decimales('[{"t":"1.234,56"}]'::jsonb, '{"valor_total":"t"}') ->> 'decimal');
SELECT _chk('num/2 1,234.56 es gringo', '.',
  ingesta_inferir_decimales('[{"t":"1,234.56"}]'::jsonb, '{"valor_total":"t"}') ->> 'decimal');
SELECT _chk('num/3 sin separadores, miles vacío', '',
  ingesta_inferir_decimales('[{"t":"31600"}]'::jsonb, '{"valor_total":"t"}') ->> 'miles');
-- Una descripción con comas no opina sobre el separador decimal.
SELECT _chk('num/4 el texto no contamina', '.',
  ingesta_inferir_decimales('[{"p":"ARROZ, BLANCO, 500G","t":"31600"}]'::jsonb,
    '{"producto":"p","valor_total":"t"}') ->> 'decimal');

-- ===========================================================================
-- VENTA O COMPRA
-- ===========================================================================
SELECT _doc('compras_marzo.csv',  '\xA1') AS d_com \gset
SELECT _doc('ventas_detalle.csv', '\xA2') AS d_ven \gset
SELECT _chk('tipo/1 el nombre dice compra', 'compra',
  ingesta_inferir_tipo(:d_com, ARRAY['Fecha','Total']));
SELECT _chk('tipo/2 el nombre dice venta', 'venta',
  ingesta_inferir_tipo(:d_ven, ARRAY['Fecha','Total']));
SELECT _doc('export_2026.csv', '\xA3') AS d_neu \gset
SELECT _chk('tipo/3 sin pista en el nombre, manda la columna', 'compra',
  ingesta_inferir_tipo(:d_neu, ARRAY['Fecha','Proveedor','Total']));
SELECT _chk('tipo/4 sin ninguna pista, venta', 'venta',
  ingesta_inferir_tipo(:d_neu, ARRAY['Fecha','Total']));

-- ===========================================================================
-- EL AGREGADO: la regla que evita el doble conteo de $288 millones
-- ===========================================================================
-- Fecha + plata, sin producto NI cantidad = resumen.
SELECT _chk('agregado/1 cierre_caja es agregado', 'true',
  ingesta_es_agregado(ingesta_resolver_columnas(
    ARRAY['Fecha','Total_Ventas','Nro_Transacciones']))::text);

-- El detalle NO es agregado, obviamente: si esto falla se rechaza todo.
SELECT _chk('agregado/2 el detalle no es agregado', 'false',
  ingesta_es_agregado(ingesta_resolver_columnas(
    ARRAY['Fecha','Producto','Cantidad','Valor_Unitario','Total_Linea']))::text);

-- Basta UNA de las dos señales para que sea un libro legítimo. Se exige que
-- falten las dos a propósito: pedir solo `producto` daría falsos positivos con
-- un libro cuya columna de descripción no reconocimos.
SELECT _chk('agregado/3 con cantidad y sin producto NO es agregado', 'false',
  ingesta_es_agregado('{"fecha":"F","cantidad":"C","valor_total":"T"}'::jsonb)::text);
SELECT _chk('agregado/4 con producto y sin cantidad NO es agregado', 'false',
  ingesta_es_agregado('{"fecha":"F","producto":"P","valor_total":"T"}'::jsonb)::text);

-- ===========================================================================
-- EL RESOLVER COMPLETO Y SU PUERTA
-- ===========================================================================
SELECT _doc('ventas_detalle_2026-03.csv', '\xB1') AS d1 \gset

SELECT _chk('mapeo/1 el detalle real se resuelve sin modelo', 'true',
  (ingesta_inferir_mapeo_sql(:d1,
     ARRAY['Fecha','Producto','Categoria','Cantidad','Valor_Unitario',
           'Total_Linea','Codigo_Barras','Unidad'],
     '[{"Fecha":"2026-03-01","Total_Linea":"31600"}]'::jsonb) ->> 'resuelto'));

SELECT _chk('mapeo/2 y trae el formato de fecha leído', 'YYYY-MM-DD',
  (ingesta_inferir_mapeo_sql(:d1,
     ARRAY['Fecha','Producto','Cantidad','Total_Linea'],
     '[{"Fecha":"2026-03-01","Total_Linea":"31600"}]'::jsonb) ->> 'formato_fecha'));

-- Sin fecha reconocible NO se inventa nada: ahí sí vale gastar la llamada.
SELECT _chk('mapeo/3 sin columna de fecha -> al modelo', 'false',
  (ingesta_inferir_mapeo_sql(:d1, ARRAY['Chuchoqueo','Total'], '[]'::jsonb) ->> 'resuelto'));
SELECT _chk('mapeo/4 y dice por qué', 'no reconocí la columna de fecha',
  (ingesta_inferir_mapeo_sql(:d1, ARRAY['Chuchoqueo','Total'], '[]'::jsonb) ->> 'motivo'));
SELECT _chk('mapeo/5 sin columna de valor -> al modelo', 'no reconocí la columna de valor',
  (ingesta_inferir_mapeo_sql(:d1, ARRAY['Fecha','Producto'], '[]'::jsonb) ->> 'motivo'));

-- ===========================================================================
-- DE PUNTA A PUNTA: identificar sin gastar una llamada
-- ===========================================================================
SELECT _doc('ventas_detalle_2026-04.csv', '\xC1') AS d2 \gset

SELECT ingesta_identificar_tabular(:d2,
  ARRAY['Fecha','Producto','Categoria','Cantidad','Valor_Unitario',
        'Total_Linea','Codigo_Barras','Unidad'],
  '[{"Fecha":"2026-04-01","Total_Linea":"31600","Cantidad":"2"}]'::jsonb) AS ident \gset

SELECT _chk('e2e/1 huella nueva y AUN ASÍ sin modelo', 'false',
  ((:'ident')::jsonb ->> 'requiere_inferencia'));
SELECT _chk('e2e/2 lo resolvió el SQL, no el modelo', 'sql',
  ((:'ident')::jsonb ->> 'origen'));
SELECT _chk('e2e/3 el formato quedó asignado al documento', 'si',
  CASE WHEN (SELECT formato_codigo FROM documentos WHERE id = :d2) IS NOT NULL
       THEN 'si' ELSE 'no' END);

-- El segundo archivo del mismo POS ya ni siquiera resuelve: pega en la caché.
SELECT _doc('ventas_detalle_2026-05.csv', '\xC2') AS d3 \gset
SELECT _chk('e2e/4 el segundo archivo pega en la caché', 'cache',
  (ingesta_identificar_tabular(:d3,
     ARRAY['Fecha','Producto','Categoria','Cantidad','Valor_Unitario',
           'Total_Linea','Codigo_Barras','Unidad'],
     '[]'::jsonb) ->> 'origen'));

-- Y carga de verdad: el mapeo resuelto sin modelo tiene que producir
-- movimientos con fecha y plata, no filas vacías.
SELECT ingesta_cargar_tabular(:d3, '[
  {"Fecha":"2026-05-02","Producto":"ARROZ 500G","Categoria":"GRANOS",
   "Cantidad":"2","Valor_Unitario":"3100","Total_Linea":"6200",
   "Codigo_Barras":"7700001","Unidad":"und"},
  {"Fecha":"2026-05-03","Producto":"ACEITE 1L","Categoria":"ACEITES",
   "Cantidad":"1","Valor_Unitario":"12500","Total_Linea":"12500",
   "Codigo_Barras":"7700002","Unidad":"und"}]'::jsonb) AS carga \gset

SELECT _chk('e2e/5 cargó las dos filas', '2',
  (SELECT count(*)::text FROM movimientos WHERE documento_id = :d3));
SELECT _chk('e2e/6 con la fecha bien leída', '2026-05-02',
  (SELECT min(fecha)::text FROM movimientos WHERE documento_id = :d3));
SELECT _chk('e2e/7 y con la plata bien leída', '18700',
  (SELECT sum(valor_total)::text FROM movimientos WHERE documento_id = :d3));
SELECT _chk('e2e/8 el producto llegó a raw para el matching', 'ARROZ 500G',
  (SELECT raw ->> 'producto' FROM movimientos
    WHERE documento_id = :d3 ORDER BY fecha LIMIT 1));

-- ===========================================================================
-- EL CIERRE DE CAJA NO ENTRA A MOVIMIENTOS
-- ===========================================================================
SELECT _doc('cierre_caja_2026-03.csv', '\xD1') AS d4 \gset

SELECT ingesta_identificar_tabular(:d4,
  ARRAY['Fecha','Total_Ventas','Nro_Transacciones'],
  '[{"Fecha":"2026-03-01","Total_Ventas":"1250000"}]'::jsonb) AS ident2 \gset

SELECT _chk('cierre/1 se reconoce sin modelo', 'false',
  ((:'ident2')::jsonb ->> 'requiere_inferencia'));
SELECT _chk('cierre/2 y queda marcado como agregado', 'true',
  ((:'ident2')::jsonb ->> 'agregado'));

-- LA aserción: cargarlo no mete NI UN movimiento.
SELECT ingesta_cargar_tabular(:d4,
  '[{"Fecha":"2026-03-01","Total_Ventas":"1250000","Nro_Transacciones":"87"},
    {"Fecha":"2026-03-02","Total_Ventas":"980000","Nro_Transacciones":"64"}]'::jsonb) AS c2 \gset

SELECT _chk('cierre/3 CERO movimientos insertados', '0',
  (SELECT count(*)::text FROM movimientos WHERE documento_id = :d4));
SELECT _chk('cierre/4 el documento queda en error', 'error',
  (SELECT estado::text FROM documentos WHERE id = :d4));
SELECT _chk('cierre/5 y el motivo explica el doble conteo', 'si',
  CASE WHEN (SELECT error FROM documentos WHERE id = :d4) LIKE '%dos veces%'
       THEN 'si' ELSE 'no' END);

-- ===========================================================================
-- LA COMPUERTA VALE TAMBIÉN PARA EL MODELO
-- ===========================================================================
-- Si el diccionario no alcanzó y contestó el modelo, el mapeo pasa por la MISMA
-- regla. Este es literalmente el mapeo que el modelo generó en la prueba de
-- usuario y que causó el doble conteo.
SELECT _doc('resumen_raro.csv', '\xE1') AS d5 \gset
SELECT _chk('modelo/1 un agregado inferido por el modelo se marca igual', 'true',
  (ingesta_registrar_formato_inferido(:d5, ARRAY['Fecha','Total_Ventas'],
     '{"tipo":"venta","decimal":".","miles":"","formato_fecha":"YYYY-MM-DD",
       "columnas":{"fecha":"Fecha","valor_total":"Total_Ventas"}}'::jsonb)
   ->> 'agregado'));

SELECT ingesta_cargar_tabular(:d5,
  '[{"Fecha":"2026-03-01","Total_Ventas":"1250000"}]'::jsonb) AS c3 \gset
SELECT _chk('modelo/2 y tampoco entra a movimientos', '0',
  (SELECT count(*)::text FROM movimientos WHERE documento_id = :d5));

-- ===========================================================================
-- CUÁNTAS LLAMADAS COSTÓ TODO ESTO
-- ===========================================================================
-- Cinco archivos tabulares procesados de punta a punta en este banco y ni una
-- sola vez se prendió `requiere_inferencia`. Ese es el objetivo entero de la
-- migración, así que se afirma explícitamente.
SELECT _chk('costo/1 ningún archivo del banco necesitó el modelo', 'no',
  (SELECT CASE WHEN bool_or(
     (ingesta_identificar_tabular(d.id, ARRAY['Fecha','Producto','Cantidad','Total_Linea'],
        '[{"Fecha":"2026-03-01","Total_Linea":"1"}]'::jsonb)
      ->> 'requiere_inferencia')::boolean)
   THEN 'si' ELSE 'no' END
   FROM documentos d WHERE d.id IN (:d1, :d2, :d3)));

-- ===========================================================================
-- RESUMEN
-- ===========================================================================
\echo ''
SELECT prueba, coalesce(esperado,'(NULL)') AS esperado,
       coalesce(obtenido,'(NULL)') AS obtenido,
       CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS res
FROM r ORDER BY ok, prueba;

SELECT count(*) FILTER (WHERE ok) AS pasaron,
       count(*) FILTER (WHERE NOT ok) AS fallaron,
       count(*) AS total
FROM r;

ROLLBACK;
