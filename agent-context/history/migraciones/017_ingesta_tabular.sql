-- 017_ingesta_tabular.sql — la ingesta tabular deja de asumir un esquema fijo.
--
-- Qué estaba mal (verificado, no teórico):
--
--   1. Un CSV de otro POS se cargaba como éxito con TODOS los campos de negocio
--      en NULL. `r ->> 'fecha'` sobre una fila cuya columna se llama
--      "Fecha Venta" da NULL, y movimientos.fecha/cantidad/valor_* son
--      nullable. El documento quedaba 'parseado' y el informe corría sobre
--      filas vacías. Corrupción silenciosa, que es peor que rechazar.
--   2. `mapeo` declaraba "decimal" y "separador" y la función NUNCA los leía:
--      casteaba directo con ::date y ::numeric.
--   3. El contenedor corre con DateStyle = ISO, MDY, así que '12/03/2026'::date
--      da 2026-12-03 (3 de diciembre) en vez del 12 de marzo. No falla: guarda
--      el dato equivocado. Cualquier export dd/mm de un POS latino entraba mal.
--   4. Un .xlsx se rechazaba con 'formato no reconocido' porque ninguna fila de
--      formatos_documento lo reclamaba, aunque el nodo Extract from File de n8n
--      ya sabe leer xlsx/xls/ods.
--   5. match_resolver_documento busca raw->>'producto' o raw->>'descripcion'.
--      Como raw guardaba la fila original tal cual, un POS con la columna
--      "Descripcion" (mayúscula) dejaba todo sin resolver.
--
-- Cómo queda: la identificación del formato pasa a ser en dos fases. Por
-- mime/extensión se decide la CLASE (documento que Postgres parsea solo, o
-- tabla que n8n debe extraer primero). Para las tablas, el formato se
-- identifica por la HUELLA de sus cabeceras. Si la huella es nueva, n8n le
-- pide un mapeo al LLM, se valida y se persiste como fila: el segundo archivo
-- de ese mismo POS ya no gasta tokens. El LLM nunca ve las cifras, solo los
-- nombres de las columnas y una muestra: infiere el mapeo, no los datos.

-- === 1. Clase, huella y procedencia de cada formato =========================
ALTER TABLE formatos_documento
    ADD COLUMN clase  text NOT NULL DEFAULT 'documento'
        CHECK (clase IN ('documento','tabular')),
    -- Huella de las cabeceras: identifica un layout de POS sin depender del
    -- nombre del archivo, que es basura para esto.
    ADD COLUMN huella text,
    -- 'semilla' = escrita a mano; 'inferido' = la escribió el sistema.
    ADD COLUMN origen text NOT NULL DEFAULT 'semilla'
        CHECK (origen IN ('semilla','inferido'));

CREATE UNIQUE INDEX uq_formato_huella ON formatos_documento (huella)
    WHERE huella IS NOT NULL;

-- Extensión -> operación del nodo Extract from File de n8n. Estar en este mapa
-- ES la definición de "esto es una tabla". Una fila, no un condicional.
INSERT INTO parametros (negocio_id, clave, valor) VALUES
  (NULL, 'ingesta_extractores', '{"csv":"csv","tsv":"csv","txt":"csv",
                                  "xls":"xls","xlsx":"xlsx","ods":"ods"}'::jsonb)
ON CONFLICT DO NOTHING;

-- === 2. Prompts que no son de un servicio ==================================
-- prompts.servicio_codigo tiene FK a servicios, así que el prompt de
-- inferencia de mapeo no cabe ahí. Sigue siendo contenido: sigue en una fila.
CREATE TABLE prompts_tecnicos (
    clave       text PRIMARY KEY,
    sistema     text    NOT NULL,
    usuario     text    NOT NULL,
    modelo      text    NOT NULL DEFAULT 'deepseek-v4-flash',
    temperatura numeric NOT NULL DEFAULT 0.0,
    max_tokens  integer NOT NULL DEFAULT 800,
    activo      boolean NOT NULL DEFAULT true
);

INSERT INTO prompts_tecnicos (clave, sistema, usuario, temperatura) VALUES
('ingesta.inferir_mapeo',
'Eres un experto en formatos de exportación de sistemas POS y planillas de cálculo de comercios latinoamericanos.
Recibes los nombres de las columnas de un archivo y unas filas de muestra. Devuelves SOLO un objeto JSON, sin explicación y sin bloque de código, con esta forma exacta:

{"tipo":"venta"|"compra",
 "decimal":".", "miles":",",
 "formato_fecha":"<patrón to_date de Postgres, p.ej. DD/MM/YYYY>",
 "columnas":{"fecha":"<nombre exacto>","producto":"<nombre exacto>","cantidad":"<nombre exacto>","valor_unitario":"<nombre exacto>","valor_total":"<nombre exacto>","categoria":"<nombre exacto>","codigo":"<nombre exacto>","unidad":"<nombre exacto>"}}

Reglas duras:
- Los valores de "columnas" deben ser nombres EXACTOS de la lista de columnas recibida, copiados carácter por carácter. Nunca los inventes ni los traduzcas.
- Incluye en "columnas" solo las claves que realmente existan en el archivo. Omite las demás; no pongas null ni cadenas vacías.
- "fecha" y al menos uno de "valor_total" o "valor_unitario" son obligatorios. Si no los encuentras, devuelve {"error":"faltan columnas obligatorias"}.
- "decimal" y "miles" descríbelos mirando la muestra: si ves "1.234,56" entonces decimal es "," y miles es "."; si ves "1,234.56" es al revés. Si los números no tienen separador de miles, usa "" en "miles".
- "formato_fecha" deducelo de la muestra. Ante 03/04/2026 en un comercio latinoamericano asume DD/MM/YYYY. Si las fechas ya vienen como 2026-04-03, usa YYYY-MM-DD.
- "tipo" es "compra" si el archivo son facturas o entradas de proveedor, "venta" si son ventas al cliente. Si dudas, "venta".
- No inventes ninguna cifra. No devuelvas datos de las filas.',
'Columnas del archivo:
{{columnas}}

Filas de muestra:
{{muestra}}',
0.0);

-- === 3. Normalizadores ======================================================
-- Reciben jsonb, no text, a propósito: hay que distinguir un número real (lo
-- que devuelve n8n al leer un xlsx) de un texto con separadores ("1.234,56").
-- Aplicarle reglas de separadores a un número real lo destruye: replace('.','')
-- sobre 2500.5 da 25005.

CREATE FUNCTION ingesta_num(p_valor jsonb, p_decimal text DEFAULT '.',
                            p_miles text DEFAULT ',')
RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_txt text;
    v_neg boolean := false;
BEGIN
    IF p_valor IS NULL OR jsonb_typeof(p_valor) IN ('null','object','array') THEN
        RETURN NULL;
    END IF;

    -- Ya es número: no tocarlo.
    IF jsonb_typeof(p_valor) = 'number' THEN
        RETURN (p_valor #>> '{}')::numeric;
    END IF;

    v_txt := btrim(p_valor #>> '{}');
    IF v_txt = '' THEN RETURN NULL; END IF;

    -- Negativo contable: (1.234,50)
    IF v_txt ~ '^\(.*\)$' THEN
        v_neg := true;
        v_txt := btrim(v_txt, '()');
    END IF;
    IF v_txt ~ '^-' THEN v_neg := true; END IF;

    -- Primero los miles (se van), después la coma decimal pasa a punto.
    IF coalesce(p_miles, '') <> '' THEN
        v_txt := replace(v_txt, p_miles, '');
    END IF;
    IF coalesce(p_decimal, '.') <> '.' THEN
        v_txt := replace(v_txt, p_decimal, '.');
    END IF;

    -- Fuera símbolo de moneda, espacios (incluido el no-separable), letras.
    v_txt := regexp_replace(v_txt, '[^0-9.]', '', 'g');
    IF v_txt = '' OR v_txt = '.' THEN RETURN NULL; END IF;

    -- Un archivo mal declarado puede dejar varios puntos: no adivinar.
    IF length(v_txt) - length(replace(v_txt, '.', '')) > 1 THEN
        RETURN NULL;
    END IF;

    RETURN CASE WHEN v_neg THEN -v_txt::numeric ELSE v_txt::numeric END;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;   -- un valor ilegible es NULL, y la compuerta lo cuenta
END;
$$;

CREATE FUNCTION ingesta_fecha(p_valor jsonb, p_formato text DEFAULT NULL)
RETURNS date LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_txt text;
    v_n   numeric;
BEGIN
    IF p_valor IS NULL OR jsonb_typeof(p_valor) IN ('null','object','array') THEN
        RETURN NULL;
    END IF;

    -- Serial de Excel: los xlsx sin cellDates traen 46000 en vez de una fecha.
    -- La época de Excel es 1899-12-30 por su bug del año bisiesto de 1900.
    IF jsonb_typeof(p_valor) = 'number' THEN
        v_n := (p_valor #>> '{}')::numeric;
        IF v_n BETWEEN 20000 AND 80000 THEN
            RETURN date '1899-12-30' + (floor(v_n))::int;
        END IF;
        RETURN NULL;
    END IF;

    v_txt := btrim(p_valor #>> '{}');
    IF v_txt = '' THEN RETURN NULL; END IF;
    -- Recorta la parte de hora si viene (ISO o "12/03/2026 14:22").
    v_txt := split_part(split_part(v_txt, 'T', 1), ' ', 1);

    IF coalesce(p_formato, '') <> '' THEN
        RETURN to_date(v_txt, p_formato);
    END IF;

    -- Sin formato declarado solo se acepta ISO. dd/mm y mm/dd son
    -- indistinguibles y adivinar fue justo el bug de este archivo: mejor NULL
    -- y que la compuerta obligue a declarar formato_fecha en el mapeo.
    IF v_txt ~ '^\d{4}-\d{2}-\d{2}$' THEN
        RETURN v_txt::date;
    END IF;
    RETURN NULL;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$;

-- Huella de un layout: cabeceras normalizadas y ordenadas. No depende del
-- orden de las columnas ni de acentos, mayúsculas o espacios dobles.
CREATE FUNCTION ingesta_huella(p_columnas text[])
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT md5(string_agg(c, '|' ORDER BY c))
    FROM (SELECT DISTINCT norm_texto(unnest) AS c
          FROM unnest(p_columnas)
          WHERE btrim(coalesce(unnest,'')) <> '') s;
$$;

-- === 4. Registro del documento: detección en dos fases ======================
CREATE OR REPLACE FUNCTION ingesta_registrar_documento(
    p_sesion_id      bigint,
    p_negocio_id     bigint,
    p_nombre_archivo text,
    p_mime           text,
    p_contenido      bytea
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_hash      bytea := digest(p_contenido, 'sha256');
    v_id        bigint;
    v_formato   text;
    v_ext       text := lower(split_part(p_nombre_archivo, '.', -1));
    v_op        text;
    v_duplicado boolean := false;
BEGIN
    -- Fase 1a: ¿es un documento que Postgres parsea solo? (DIAN XML)
    SELECT codigo INTO v_formato
    FROM formatos_documento
    WHERE activo AND clase = 'documento'
      AND ( lower(coalesce(p_mime,'')) = ANY(mime_patrones)
            OR v_ext = ANY(extensiones) )
    ORDER BY codigo
    LIMIT 1;

    -- Fase 1b: ¿es una tabla? El formato exacto no se sabe todavía: depende de
    -- las cabeceras, que solo n8n puede leer. Se deja formato_codigo NULL.
    IF v_formato IS NULL THEN
        v_op := (parametro(p_negocio_id, 'ingesta_extractores')) ->> v_ext;
    END IF;

    INSERT INTO documentos (sesion_id, negocio_id, formato_codigo, nombre_archivo,
                            mime, hash, contenido, tamano, estado)
    VALUES (p_sesion_id, p_negocio_id, v_formato, p_nombre_archivo,
            p_mime, v_hash, p_contenido, octet_length(p_contenido), 'pendiente')
    ON CONFLICT (negocio_id, hash) DO UPDATE SET sesion_id = EXCLUDED.sesion_id
    RETURNING id INTO v_id;

    SELECT (xmax <> 0) INTO v_duplicado FROM documentos WHERE id = v_id;

    IF v_formato IS NULL AND v_op IS NULL THEN
        RETURN ingesta_marcar_error(v_id,
                 format('no sé leer archivos %s', coalesce(nullif(v_ext,''), 'sin extensión')))
               || jsonb_build_object('documento_id', v_id, 'reconocido', false,
                                     'requiere_tabla', false);
    END IF;

    RETURN jsonb_build_object(
        'documento_id',   v_id,
        'formato',        v_formato,
        'duplicado',      v_duplicado,
        'reconocido',     true,
        -- n8n mira esto para saber si tiene que extraer la tabla primero.
        'requiere_tabla', v_formato IS NULL,
        'operacion',      v_op,
        'extension',      v_ext
    );
END;
$$;

-- === 5. Identificación del layout por huella ===============================
-- n8n llama a esta con las cabeceras que extrajo. Si la huella ya se conoce,
-- el formato queda asignado y no se gasta un solo token.
CREATE FUNCTION ingesta_identificar_tabular(p_documento_id bigint,
                                            p_columnas text[])
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_huella  text := ingesta_huella(p_columnas);
    v_formato text;
BEGIN
    IF v_huella IS NULL THEN
        RETURN ingesta_marcar_error(p_documento_id,
                 'el archivo no tiene cabeceras legibles')
               || jsonb_build_object('requiere_inferencia', false);
    END IF;

    SELECT codigo INTO v_formato FROM formatos_documento
    WHERE activo AND clase = 'tabular' AND huella = v_huella;

    IF v_formato IS NOT NULL THEN
        UPDATE documentos SET formato_codigo = v_formato WHERE id = p_documento_id;
        RETURN jsonb_build_object('documento_id', p_documento_id,
                                  'formato', v_formato, 'huella', v_huella,
                                  'requiere_inferencia', false);
    END IF;

    RETURN jsonb_build_object('documento_id', p_documento_id, 'huella', v_huella,
                              'columnas', to_jsonb(p_columnas),
                              'requiere_inferencia', true);
END;
$$;

-- === 6. Persistir un mapeo inferido por el LLM =============================
-- Valida antes de guardar. Un mapeo malo persistido envenena todos los
-- archivos futuros de ese POS, así que acá se es estricto: claves canónicas,
-- columnas que existan de verdad, y las obligatorias presentes.
CREATE FUNCTION ingesta_registrar_formato_inferido(
    p_documento_id bigint,
    p_columnas     text[],
    p_mapeo        jsonb
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_canonicas text[] := ARRAY['fecha','producto','categoria','cantidad',
                                'valor_unitario','valor_total','codigo','unidad','impuesto'];
    v_huella  text := ingesta_huella(p_columnas);
    v_cols    jsonb := p_mapeo -> 'columnas';
    v_limpio  jsonb := '{}'::jsonb;
    v_codigo  text;
    v_ext     text;
    k text; val text;
BEGIN
    IF p_mapeo ? 'error' THEN
        RETURN ingesta_marcar_error(p_documento_id,
                 format('no reconocí las columnas del archivo (%s)', p_mapeo ->> 'error'));
    END IF;

    IF v_cols IS NULL OR jsonb_typeof(v_cols) <> 'object' THEN
        RETURN ingesta_marcar_error(p_documento_id, 'no pude interpretar las columnas del archivo');
    END IF;

    -- Solo claves canónicas y solo columnas que existan en el archivo.
    FOR k, val IN SELECT * FROM jsonb_each_text(v_cols) LOOP
        IF k = ANY(v_canonicas) AND coalesce(val,'') <> ''
           AND EXISTS (SELECT 1 FROM unnest(p_columnas) c WHERE c = val) THEN
            v_limpio := v_limpio || jsonb_build_object(k, val);
        END IF;
    END LOOP;

    IF NOT (v_limpio ? 'fecha')
       OR NOT (v_limpio ? 'valor_total' OR v_limpio ? 'valor_unitario') THEN
        RETURN ingesta_marcar_error(p_documento_id,
                 'al archivo le falta la columna de fecha o la de valor');
    END IF;

    SELECT lower(split_part(nombre_archivo, '.', -1)) INTO v_ext
    FROM documentos WHERE id = p_documento_id;

    v_codigo := 'tabular_' || left(v_huella, 10);

    INSERT INTO formatos_documento (codigo, nombre, mime_patrones, extensiones,
                                    funcion_parseo, deteccion, mapeo, clase,
                                    huella, origen)
    VALUES (v_codigo,
            format('Tabla inferida (%s)', coalesce(nullif(v_ext,''),'?')),
            '{}', ARRAY[coalesce(nullif(v_ext,''),'csv')],
            'ingesta_cargar_tabular', '{}'::jsonb,
            jsonb_build_object(
              'tipo',          coalesce(p_mapeo ->> 'tipo', 'venta'),
              'decimal',       coalesce(p_mapeo ->> 'decimal', '.'),
              'miles',         coalesce(p_mapeo ->> 'miles', ''),
              'formato_fecha', p_mapeo ->> 'formato_fecha',
              'columnas',      v_limpio),
            'tabular', v_huella, 'inferido')
    ON CONFLICT (codigo) DO UPDATE SET mapeo = EXCLUDED.mapeo
    RETURNING codigo INTO v_codigo;

    UPDATE documentos SET formato_codigo = v_codigo WHERE id = p_documento_id;

    RETURN jsonb_build_object('documento_id', p_documento_id, 'formato', v_codigo,
                              'huella', v_huella, 'columnas_mapeadas', v_limpio,
                              'nuevo', true);
END;
$$;

-- === 7. Carga tabular: normaliza, valida, y solo entonces inserta ==========
CREATE OR REPLACE FUNCTION ingesta_cargar_tabular(p_documento_id bigint, p_filas jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_negocio_id bigint;
    v_mapeo      jsonb;
    v_cols       jsonb;
    v_tipo       text;
    v_dec        text;
    v_mil        text;
    v_fmt        text;
    v_max_nulos  numeric;
    v_n          int;
    v_sin_fecha  int;
    v_sin_valor  int;
    v_pct_fecha  numeric;
    v_pct_valor  numeric;
BEGIN
    SELECT d.negocio_id, f.mapeo INTO v_negocio_id, v_mapeo
    FROM documentos d JOIN formatos_documento f ON f.codigo = d.formato_codigo
    WHERE d.id = p_documento_id;

    IF v_mapeo IS NULL THEN
        RETURN ingesta_marcar_error(p_documento_id, 'el documento no tiene formato asignado');
    END IF;

    v_cols      := v_mapeo -> 'columnas';
    v_tipo      := coalesce(v_mapeo ->> 'tipo', 'venta');
    v_dec       := coalesce(v_mapeo ->> 'decimal', '.');
    v_mil       := coalesce(v_mapeo ->> 'miles', '');
    v_fmt       := v_mapeo ->> 'formato_fecha';
    v_max_nulos := coalesce((v_mapeo ->> 'max_pct_nulos')::numeric, 20);

    -- Una sola sentencia: normaliza, mide, y solo inserta si la compuerta pasa.
    -- Insertar y después arrepentirse es justo lo que dejaba basura en
    -- movimientos, y un RETURN no revierte lo ya insertado.
    WITH norm AS (
        SELECT ingesta_fecha(r -> (v_cols ->> 'fecha'), v_fmt)                  AS fecha,
               ingesta_num  (r -> (v_cols ->> 'cantidad'),       v_dec, v_mil)  AS cantidad,
               ingesta_num  (r -> (v_cols ->> 'valor_unitario'), v_dec, v_mil)  AS valor_unitario,
               ingesta_num  (r -> (v_cols ->> 'valor_total'),    v_dec, v_mil)  AS valor_total,
               -- La fila original se conserva entera para auditoría, y encima
               -- se le pegan las claves canónicas que match_resolver_documento
               -- busca (producto/codigo/unidad). Sin esto, un POS con la
               -- columna "Descripcion" dejaba todo sin resolver.
               r || jsonb_strip_nulls(jsonb_build_object(
                      'producto',  r ->> (v_cols ->> 'producto'),
                      'categoria', r ->> (v_cols ->> 'categoria'),
                      'codigo',    r ->> (v_cols ->> 'codigo'),
                      'unidad',    r ->> (v_cols ->> 'unidad')))                AS raw
        FROM jsonb_array_elements(coalesce(p_filas, '[]'::jsonb)) AS r
    ),
    medida AS (
        SELECT count(*)::int                                                       AS n,
               count(*) FILTER (WHERE fecha IS NULL)::int                          AS sin_fecha,
               count(*) FILTER (WHERE valor_total IS NULL
                                  AND valor_unitario IS NULL)::int                 AS sin_valor
        FROM norm
    ),
    compuerta AS (
        SELECT n, sin_fecha, sin_valor,
               round(sin_fecha * 100.0 / greatest(n,1), 1) AS pct_fecha,
               round(sin_valor * 100.0 / greatest(n,1), 1) AS pct_valor,
               n > 0
                 AND round(sin_fecha * 100.0 / greatest(n,1), 1) <= v_max_nulos
                 AND round(sin_valor * 100.0 / greatest(n,1), 1) <= v_max_nulos AS pasa
        FROM medida
    ),
    ins AS (
        INSERT INTO movimientos (negocio_id, documento_id, tipo, fecha,
                                 cantidad, valor_unitario, valor_total, raw)
        SELECT v_negocio_id, p_documento_id, v_tipo::tipo_movimiento,
               nm.fecha, nm.cantidad,
               coalesce(nm.valor_unitario,
                        CASE WHEN nm.cantidad > 0 THEN nm.valor_total / nm.cantidad END),
               coalesce(nm.valor_total, nm.valor_unitario * nm.cantidad),
               nm.raw
        FROM norm nm CROSS JOIN compuerta c
        WHERE c.pasa
        RETURNING 1
    )
    SELECT n, sin_fecha, sin_valor, pct_fecha, pct_valor
      INTO v_n, v_sin_fecha, v_sin_valor, v_pct_fecha, v_pct_valor
    FROM compuerta;

    IF v_n = 0 THEN
        RETURN ingesta_marcar_error(p_documento_id, 'el archivo no tiene filas de datos');
    END IF;

    -- Compuerta. Si el mapeo no aplicó, el archivo NO queda parseado y no se
    -- insertó nada: el CROSS JOIN de arriba dejó el INSERT en cero filas.
    IF v_pct_fecha > v_max_nulos THEN
        RETURN ingesta_marcar_error(p_documento_id,
                 format('no pude leer la fecha en %s%% de las %s filas (columna "%s", formato %s)',
                        v_pct_fecha, v_n, coalesce(v_cols ->> 'fecha','?'),
                        coalesce(v_fmt,'sin declarar')))
               || jsonb_build_object('filas', v_n, 'pct_sin_fecha', v_pct_fecha);
    END IF;

    IF v_pct_valor > v_max_nulos THEN
        RETURN ingesta_marcar_error(p_documento_id,
                 format('no pude leer el valor en %s%% de las %s filas (columnas "%s"/"%s", decimal "%s")',
                        v_pct_valor, v_n, coalesce(v_cols ->> 'valor_total','?'),
                        coalesce(v_cols ->> 'valor_unitario','?'), v_dec))
               || jsonb_build_object('filas', v_n, 'pct_sin_valor', v_pct_valor);
    END IF;

    UPDATE documentos SET estado = 'parseado', error = NULL WHERE id = p_documento_id;

    RETURN jsonb_build_object('documento_id', p_documento_id, 'estado', 'parseado',
                              'filas', v_n, 'tipo', v_tipo,
                              'pct_sin_fecha', v_pct_fecha,
                              'pct_sin_valor', v_pct_valor);
END;
$$;

-- === 8. Resumen para devolverle al usuario lo entendido ====================
-- Sale de la base, no del LLM: son los datos que quedaron guardados.
CREATE FUNCTION ingesta_resumen_documento(p_documento_id bigint)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'nombre_archivo', d.nombre_archivo,
        'formato',        d.formato_codigo,
        'estado',         d.estado,
        'error',          d.error,
        'filas',          (SELECT count(*) FROM movimientos m WHERE m.documento_id = d.id),
        'desde',          (SELECT min(fecha) FROM movimientos m WHERE m.documento_id = d.id),
        'hasta',          (SELECT max(fecha) FROM movimientos m WHERE m.documento_id = d.id),
        'total',          (SELECT round(coalesce(sum(valor_total),0)) FROM movimientos m WHERE m.documento_id = d.id),
        'productos',      (SELECT count(DISTINCT coalesce(m.raw ->> 'producto', m.raw ->> 'descripcion'))
                             FROM movimientos m WHERE m.documento_id = d.id),
        'sin_resolver',   (SELECT count(*) FROM movimientos m
                            WHERE m.documento_id = d.id AND m.producto_id IS NULL)
    )
    FROM documentos d WHERE d.id = p_documento_id;
$$;

-- === 9. Despacho por clase, no por aritmética de argumentos ================
CREATE OR REPLACE FUNCTION ingesta_procesar_documento(p_documento_id bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_funcion text;
    v_clase   text;
    v_result  jsonb;
BEGIN
    SELECT f.funcion_parseo, f.clase INTO v_funcion, v_clase
    FROM documentos d
    JOIN formatos_documento f ON f.codigo = d.formato_codigo
    WHERE d.id = p_documento_id AND f.activo;

    IF v_funcion IS NULL THEN
        RETURN ingesta_marcar_error(p_documento_id, 'formato no reconocido');
    END IF;

    -- Los tabulares necesitan que n8n extraiga las filas primero; el despacho
    -- antes se deducía de pg_proc.pronargs, que era adivinar.
    IF v_clase = 'tabular' THEN
        RETURN jsonb_build_object('documento_id', p_documento_id,
                                  'requiere_filas', true, 'funcion', v_funcion);
    END IF;

    BEGIN
        EXECUTE format('SELECT %I($1)', v_funcion) INTO v_result USING p_documento_id;
    EXCEPTION WHEN OTHERS THEN
        RETURN ingesta_marcar_error(p_documento_id, SQLERRM);
    END;

    RETURN v_result;
END;
$$;

-- === 10. Reclasificar los formatos semilla =================================
UPDATE formatos_documento SET clase = 'documento' WHERE codigo = 'dian_xml';

-- El CSV del prototipo pasa a identificarse por huella como cualquier otro, y
-- su mapeo se completa con lo que la función ahora sí lee. 'separador' era
-- ambiguo (delimitador del CSV vs separador de miles): se parte en dos.
UPDATE formatos_documento
SET clase  = 'tabular',
    huella = ingesta_huella(ARRAY['fecha','producto','categoria','cantidad',
                                  'precio_unitario','total']),
    mapeo  = jsonb_build_object(
               'tipo',          'venta',
               'delimitador',   ',',
               'decimal',       '.',
               'miles',         '',
               'formato_fecha', 'YYYY-MM-DD',
               'columnas',      jsonb_build_object(
                                  'fecha',          'fecha',
                                  'producto',       'producto',
                                  'categoria',      'categoria',
                                  'cantidad',       'cantidad',
                                  'valor_unitario', 'precio_unitario',
                                  'valor_total',    'total'))
WHERE codigo = 'pos_csv_generico';
