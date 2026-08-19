-- 073_ingesta_sin_modelo.sql — la inferencia de formatos deja de gastar tokens.
--
-- Qué estaba mal (medido, no teórico):
--
--   1. Cada huella nueva costaba una llamada al modelo para resolver algo que
--      es casi todo determinista. Corrido `norm_texto` sobre las cabeceras
--      reales de la prueba de usuario, SEIS de las ocho columnas caen solas:
--
--        Fecha          -> fecha            (exacto)
--        Producto       -> producto         (exacto)
--        Categoria      -> categoria        (exacto)
--        Cantidad       -> cantidad         (exacto)
--        Valor_Unitario -> valor_unitario   (exacto)
--        Unidad         -> unidad           (exacto)
--        Total_Linea    -> valor_total      (sinónimo ^total)
--        Codigo_Barras  -> codigo           (sinónimo ^codigo)
--
--      Se le pagaron 4.000 tokens a un modelo para que hiciera un lower() con
--      guiones bajos. Con cupo de 20 peticiones diarias, diez archivos se
--      llevaron media jornada de cuota en trabajo redundante.
--
--   2. El modelo APRENDIÓ MAL un formato y nadie lo atrapó. El mapeo inferido
--      para los `cierre_caja` fue:
--
--        {"tipo":"venta","columnas":{"fecha":"Fecha","valor_total":"Total_Ventas"}}
--
--      Sin `producto` y sin `cantidad`: eso no es un libro de movimientos, es
--      un agregado diario. Se cargó como ventas individuales y quedó sumado
--      ENCIMA del detalle que ya venía en los otros archivos. Ese mapeo es la
--      causa exacta del doble conteo: 21.912 filas de detalle por $208.899.280
--      más 122 filas de cierre por $288.037.120 = $496.936.400 de ventas que el
--      negocio nunca hizo.
--
--      Un modelo no va a atrapar eso de forma confiable, porque "Total_Ventas"
--      PARECE una venta. Una regla sí.
--
-- Cómo queda:
--
--   huella conocida ─────────────────────────────────────────► cargar   (0 llamadas)
--   huella nueva → resolver determinista
--                    ├─ fecha + valor + (producto|cantidad) → cargar   (0 llamadas)
--                    ├─ fecha + valor, sin producto NI cantidad → agregado: se
--                    │    aprende el formato y se rechaza con motivo     (0 llamadas)
--                    └─ falta fecha o falta valor ───────────► el modelo, y solo
--                         entonces                                       (1 llamada)
--
-- El modelo queda para lo que es genuinamente lingüístico: narrar el informe y
-- contestar preguntas libres. La compuerta de agregados se aplica también al
-- camino del modelo, así que ya no puede volver a envenenar `movimientos`.

-- === 1. Diccionario de sinónimos de columna ================================
-- Una tabla, no un CASE: agregar el POS del próximo cliente es un INSERT, y se
-- puede hacer sin migrar. `patron` es una regex sobre norm_texto(), que ya
-- baja a minúsculas y quita acentos (004).
--
-- `prioridad` resuelve los choques: menor gana. Existe porque "Unidades" es
-- cantidad y "Unidad" es unidad de medida, y una sola pasada de regex no
-- distingue eso sin un orden explícito.
CREATE TABLE sinonimos_columna (
    canonica  text NOT NULL,
    patron    text NOT NULL,
    prioridad int  NOT NULL DEFAULT 20,
    PRIMARY KEY (canonica, patron),
    CONSTRAINT sinonimos_canonica_valida CHECK (canonica IN (
        'fecha','producto','categoria','cantidad','valor_unitario',
        'valor_total','codigo','unidad','impuesto'))
);

COMMENT ON TABLE sinonimos_columna IS
  'Cabecera de POS -> clave canónica. Evita la llamada al modelo en el caso normal.';

INSERT INTO sinonimos_columna (canonica, patron, prioridad) VALUES
  -- fecha
  ('fecha',          '^fecha$',                                10),
  ('fecha',          '^fecha[ _]?(venta|compra|emision|documento|factura|mov)', 12),
  ('fecha',          '^(fec|dia|date)$',                       15),
  ('fecha',          '^fecha',                                 20),
  -- Abreviados: FEC_VENTA, F_MOV. Los POS viejos truncan las cabeceras a 10
  -- caracteres y "fecha" es lo primero que pierden.
  ('fecha',          '^(fec|f)[ _]',                           20),
  ('fecha',          'fecha$',                                 25),

  -- producto
  ('producto',       '^producto$',                             10),
  ('producto',       '^(descripcion|articulo|mercancia)$',     12),
  ('producto',       '^(item|detalle|concepto)$',              15),
  ('producto',       '^(producto|descripcion|articulo)',       20),
  ('producto',       '^nombre[ _]?(producto|articulo|item)',   20),
  ('producto',       '^(desc|prod|art)[ _]',                   22),

  -- categoria
  ('categoria',      '^categoria$',                            10),
  ('categoria',      '^(linea|familia|grupo|rubro)$',          15),
  ('categoria',      '^(categoria|familia|departamento|rubro)', 20),

  -- cantidad
  ('cantidad',       '^cantidad$',                             10),
  ('cantidad',       '^(cant|qty|cantidades|unidades)$',       12),
  ('cantidad',       '^cant[ _]',                              15),
  ('cantidad',       '^(n|nro|num)[ _]?unidades',              15),
  ('cantidad',       '^cantidad',                              20),

  -- valor_unitario  (más específico que valor_total: va antes)
  ('valor_unitario', '^(valor|precio|costo|p|v)[ _]?unit',     10),
  -- VAL_UNIT gana sobre '^val[ _]' de valor_total por prioridad, no por suerte.
  ('valor_unitario', '^(val|prec|cost)[ _]?unit',              10),
  ('valor_unitario', 'unitario$',                              12),
  ('valor_unitario', '^(precio|pvp)$',                         15),
  ('valor_unitario', '^precio',                                20),
  ('valor_unitario', '^costo$',                                30),

  -- valor_total
  ('valor_total',    '^(valor|venta|importe|monto)[ _]?total', 10),
  ('valor_total',    '^total$',                                10),
  ('valor_total',    '^(importe|monto|subtotal|neto)$',        15),
  ('valor_total',    '^total',                                 20),
  -- VAL_TOTAL, TOT_LINEA. No se abrevia "imp": en un POS "IMP_" es impuesto
  -- tanto como importe, y meter un impuesto en valor_total infla las ventas.
  ('valor_total',    '^(tot|val)[ _]',                         22),
  ('valor_total',    'total$',                                 25),

  -- codigo
  ('codigo',         '^(codigo|sku|ean|plu|referencia)$',      10),
  ('codigo',         '^(cod|ref)$',                            12),
  ('codigo',         '^(codigo|cod)[ _]',                      15),
  ('codigo',         '^(codigo|sku|ean|barcode|referencia)',   20),

  -- unidad  (NO matchea "unidades": eso es cantidad, ver prioridad 12 arriba)
  ('unidad',         '^unidad$',                               10),
  ('unidad',         '^(und|um|uom)$',                         12),
  ('unidad',         '^u[ _]?(de[ _]?)?medida',                15),
  ('unidad',         '^(presentacion|empaque)$',               20),

  -- impuesto
  ('impuesto',       '^(impuesto|iva|tax)$',                   10),
  ('impuesto',       '^(imp|itbis|igv)$',                      12),
  ('impuesto',       '^(impuesto|iva|imp)[ _]',                15),
  ('impuesto',       '^(impuesto|iva)',                        20);

-- === 2. Resolver las columnas sin modelo ===================================
-- Asignación codiciosa por prioridad: se generan todos los pares
-- (canónica, columna) que matchean, se ordenan, y se van tomando salteando
-- las canónicas y las columnas ya usadas. Una columna sirve a UNA clave.
CREATE FUNCTION ingesta_resolver_columnas(p_columnas text[])
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_res     jsonb := '{}'::jsonb;
    v_usadas  text[] := '{}';
    r         record;
BEGIN
    FOR r IN
        WITH pares AS (
            SELECT s.canonica, c.col, c.ord, min(s.prioridad) AS prioridad
            FROM unnest(p_columnas) WITH ORDINALITY AS c(col, ord)
            JOIN sinonimos_columna s ON norm_texto(c.col) ~ s.patron
            WHERE btrim(coalesce(c.col,'')) <> ''
            GROUP BY s.canonica, c.col, c.ord
        )
        SELECT canonica, col FROM pares
        -- prioridad manda; a igual prioridad gana la columna que aparece antes
        -- en el archivo, que es un desempate estable y no depende del planner.
        ORDER BY prioridad, ord, canonica
    LOOP
        IF NOT (v_res ? r.canonica) AND NOT (r.col = ANY(v_usadas)) THEN
            v_res    := v_res || jsonb_build_object(r.canonica, r.col);
            v_usadas := v_usadas || r.col;
        END IF;
    END LOOP;

    RETURN v_res;
END;
$$;

-- === 3. Separadores decimales, leídos de la muestra =========================
-- No se adivina por país: se mira la forma de los números. "1.234,56" y
-- "1,234.56" son distinguibles sin ambigüedad; el resto cae al default.
CREATE FUNCTION ingesta_inferir_decimales(p_muestra jsonb, p_columnas jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_vals   text[] := '{}';
    v_clave  text;
    v_col    text;
    v_fila   jsonb;
    v_txt    text;
BEGIN
    -- Solo los valores de las columnas numéricas: una descripción con comas
    -- no tiene por qué opinar sobre el separador decimal.
    FOREACH v_clave IN ARRAY ARRAY['cantidad','valor_unitario','valor_total','impuesto'] LOOP
        v_col := p_columnas ->> v_clave;
        CONTINUE WHEN v_col IS NULL;
        FOR v_fila IN SELECT * FROM jsonb_array_elements(coalesce(p_muestra,'[]'::jsonb)) LOOP
            v_txt := btrim(coalesce(v_fila ->> v_col, ''));
            IF v_txt <> '' THEN v_vals := v_vals || v_txt; END IF;
        END LOOP;
    END LOOP;

    -- 1.234,56 -> miles '.', decimal ','
    IF EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v ~ '^-?\d{1,3}(\.\d{3})+,\d+$') THEN
        RETURN jsonb_build_object('decimal', ',', 'miles', '.');
    END IF;
    -- 1,234.56 -> miles ',', decimal '.'
    IF EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v ~ '^-?\d{1,3}(,\d{3})+\.\d+$') THEN
        RETURN jsonb_build_object('decimal', '.', 'miles', ',');
    END IF;
    -- 1.234.567 sin decimales -> el punto es de miles
    IF EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v ~ '^-?\d{1,3}(\.\d{3})+$')
       AND NOT EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v ~ '^-?\d+\.\d{1,2}$') THEN
        RETURN jsonb_build_object('decimal', ',', 'miles', '.');
    END IF;
    -- 1234,56 sin separador de miles
    IF EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v ~ '^-?\d+,\d{1,2}$')
       AND NOT EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v ~ '^-?\d+\.\d+$') THEN
        RETURN jsonb_build_object('decimal', ',', 'miles', '');
    END IF;

    RETURN jsonb_build_object('decimal', '.', 'miles', '');
END;
$$;

-- === 4. Formato de fecha, leído de la muestra ===============================
-- No se cuenta cuántas parsean: to_date() es tolerante y '13/05/2026' con
-- MM/DD/YYYY no falla, ROTA (da 2027-01-05). Por eso se mira la FORMA y se
-- desempata con el rango de los componentes, que es lo único concluyente.
CREATE FUNCTION ingesta_inferir_formato_fecha(p_muestra jsonb, p_columna text)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_vals text[] := '{}';
    v_fila jsonb;
    v_txt  text;
    v_sep  text;
    v_a    int;
    v_b    int;
BEGIN
    IF p_columna IS NULL THEN RETURN NULL; END IF;

    FOR v_fila IN SELECT * FROM jsonb_array_elements(coalesce(p_muestra,'[]'::jsonb)) LOOP
        v_txt := btrim(coalesce(v_fila ->> p_columna, ''));
        -- Se recorta la hora igual que ingesta_fecha, para comparar lo mismo.
        v_txt := split_part(split_part(v_txt, 'T', 1), ' ', 1);
        IF v_txt <> '' THEN v_vals := v_vals || v_txt; END IF;
    END LOOP;

    IF cardinality(v_vals) = 0 THEN RETURN NULL; END IF;

    -- ISO: sin ambigüedad posible.
    IF NOT EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v !~ '^\d{4}-\d{2}-\d{2}$') THEN
        RETURN 'YYYY-MM-DD';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v !~ '^\d{4}/\d{2}/\d{2}$') THEN
        RETURN 'YYYY/MM/DD';
    END IF;

    -- dd?s?mm?s?yyyy: hay que decidir cuál de los dos primeros es el día.
    IF NOT EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v !~ '^\d{1,2}[/-]\d{1,2}[/-]\d{4}$') THEN
        v_sep := CASE WHEN v_vals[1] ~ '-' THEN '-' ELSE '/' END;
        SELECT max(split_part(v, v_sep, 1)::int), max(split_part(v, v_sep, 2)::int)
          INTO v_a, v_b FROM unnest(v_vals) v;
        -- Un primer componente > 12 solo puede ser un día.
        IF v_a > 12 THEN RETURN 'DD' || v_sep || 'MM' || v_sep || 'YYYY'; END IF;
        -- Un segundo componente > 12 solo puede ser un día.
        IF v_b > 12 THEN RETURN 'MM' || v_sep || 'DD' || v_sep || 'YYYY'; END IF;
        -- Ambiguo de verdad: comercio latinoamericano, DD/MM. Es la misma
        -- convención que ya declara el prompt del modelo.
        RETURN 'DD' || v_sep || 'MM' || v_sep || 'YYYY';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM unnest(v_vals) v WHERE v !~ '^\d{1,2}[/-]\d{1,2}[/-]\d{2}$') THEN
        v_sep := CASE WHEN v_vals[1] ~ '-' THEN '-' ELSE '/' END;
        SELECT max(split_part(v, v_sep, 1)::int) INTO v_a FROM unnest(v_vals) v;
        IF v_a > 12 THEN RETURN 'DD' || v_sep || 'MM' || v_sep || 'YY'; END IF;
        RETURN 'DD' || v_sep || 'MM' || v_sep || 'YY';
    END IF;

    -- Serial de Excel u otra cosa: NULL y que decida ingesta_fecha, que ya sabe
    -- convertir el serial y devolver NULL en vez de un dato equivocado.
    RETURN NULL;
END;
$$;

-- === 5. Venta o compra ======================================================
-- El nombre del archivo es la señal más fuerte y la más barata. Las columnas
-- de proveedor/NIT desempatan. Ante la duda, 'venta': es lo que ya hacía el
-- prompt, y equivocarse hacia venta es visible en el informe.
CREATE FUNCTION ingesta_inferir_tipo(p_documento_id bigint, p_columnas text[])
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_nombre text;
    v_cols   text;
BEGIN
    SELECT norm_texto(nombre_archivo) INTO v_nombre
    FROM documentos WHERE id = p_documento_id;

    IF coalesce(v_nombre,'') ~ '(compra|proveedor|entrada|abastec|surtido|pedido)' THEN
        RETURN 'compra';
    END IF;
    IF coalesce(v_nombre,'') ~ '(venta|salida|pos|caja|factura|ticket)' THEN
        RETURN 'venta';
    END IF;

    SELECT norm_texto(string_agg(c, ' ')) INTO v_cols FROM unnest(p_columnas) c;
    IF coalesce(v_cols,'') ~ '(proveedor|nit[ _]?prov|razon[ _]?social)' THEN
        RETURN 'compra';
    END IF;

    RETURN 'venta';
END;
$$;

-- === 6. ¿Es un agregado y no un libro de movimientos? =======================
-- LA regla que faltaba. Un renglón, y evita el doble conteo de $288 millones.
--
-- Un libro de movimientos tiene, como mínimo, o QUÉ se movió (producto) o
-- CUÁNTO se movió (cantidad). Una tabla con fecha y plata pero sin ninguna de
-- las dos es un resumen: un cierre de caja, un total diario, un consolidado.
-- Cargarla como movimientos suma por segunda vez lo que el detalle ya trajo.
--
-- Se exige que falten LAS DOS a propósito: pedir solo `producto` daría falsos
-- positivos con un libro legítimo cuya columna de descripción no reconocimos.
CREATE FUNCTION ingesta_es_agregado(p_columnas jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT (p_columnas ? 'valor_total' OR p_columnas ? 'valor_unitario')
       AND NOT (p_columnas ? 'producto')
       AND NOT (p_columnas ? 'cantidad');
$$;

COMMENT ON FUNCTION ingesta_es_agregado(jsonb) IS
  'Fecha + plata, sin producto ni cantidad = resumen, no movimientos. Ver 073.';

-- === 7. El resolver completo ================================================
-- Devuelve un mapeo con la MISMA forma que el que devolvía el modelo, más un
-- veredicto. `resuelto` es la única puerta: si es false, n8n llama al modelo.
CREATE FUNCTION ingesta_inferir_mapeo_sql(p_documento_id bigint,
                                          p_columnas text[],
                                          p_muestra  jsonb DEFAULT '[]'::jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cols  jsonb := ingesta_resolver_columnas(p_columnas);
    v_dec   jsonb := ingesta_inferir_decimales(p_muestra, v_cols);
    v_fmt   text;
    v_tiene_valor boolean;
BEGIN
    v_fmt := ingesta_inferir_formato_fecha(p_muestra, v_cols ->> 'fecha');
    v_tiene_valor := (v_cols ? 'valor_total') OR (v_cols ? 'valor_unitario');

    -- Sin fecha o sin plata no hay nada que cargar. Puede ser que las columnas
    -- se llamen de un modo que el diccionario no cubre todavía: ahí sí vale
    -- gastar la llamada al modelo.
    IF NOT (v_cols ? 'fecha') OR NOT v_tiene_valor THEN
        RETURN jsonb_build_object(
            'resuelto', false,
            'motivo',   CASE WHEN NOT (v_cols ? 'fecha')
                             THEN 'no reconocí la columna de fecha'
                             ELSE 'no reconocí la columna de valor' END,
            'columnas', v_cols);
    END IF;

    RETURN jsonb_build_object(
        'resuelto',      true,
        'agregado',      ingesta_es_agregado(v_cols),
        'tipo',          ingesta_inferir_tipo(p_documento_id, p_columnas),
        'decimal',       v_dec ->> 'decimal',
        'miles',         v_dec ->> 'miles',
        'formato_fecha', v_fmt,
        'columnas',      v_cols);
END;
$$;

-- === 8. Persistir un formato resuelto sin modelo ============================
-- Comparte forma con ingesta_registrar_formato_inferido pero no revalida los
-- nombres: acá salieron de las propias cabeceras, no de un texto generado.
CREATE FUNCTION ingesta_registrar_formato_resuelto(
    p_documento_id bigint,
    p_columnas     text[],
    p_mapeo        jsonb
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_huella   text := ingesta_huella(p_columnas);
    v_agregado boolean := coalesce((p_mapeo ->> 'agregado')::boolean, false);
    v_codigo   text := 'tabular_' || left(v_huella, 10);
    v_ext      text;
BEGIN
    SELECT lower(split_part(nombre_archivo, '.', -1)) INTO v_ext
    FROM documentos WHERE id = p_documento_id;

    INSERT INTO formatos_documento (codigo, nombre, mime_patrones, extensiones,
                                    funcion_parseo, deteccion, mapeo, clase,
                                    huella, origen)
    VALUES (v_codigo,
            format('Tabla %s (%s)',
                   CASE WHEN v_agregado THEN 'agregada' ELSE 'reconocida' END,
                   coalesce(nullif(v_ext,''),'?')),
            '{}', ARRAY[coalesce(nullif(v_ext,''),'csv')],
            'ingesta_cargar_tabular', '{}'::jsonb,
            jsonb_build_object(
              'tipo',          coalesce(p_mapeo ->> 'tipo', 'venta'),
              'decimal',       coalesce(p_mapeo ->> 'decimal', '.'),
              'miles',         coalesce(p_mapeo ->> 'miles', ''),
              'formato_fecha', p_mapeo ->> 'formato_fecha',
              'agregado',      v_agregado,
              'columnas',      p_mapeo -> 'columnas'),
            'tabular', v_huella, 'inferido')
    ON CONFLICT (codigo) DO UPDATE SET mapeo = EXCLUDED.mapeo
    RETURNING codigo INTO v_codigo;

    UPDATE documentos SET formato_codigo = v_codigo WHERE id = p_documento_id;

    RETURN jsonb_build_object('documento_id', p_documento_id, 'formato', v_codigo,
                              'huella', v_huella, 'agregado', v_agregado,
                              'origen', 'sql', 'nuevo', true);
END;
$$;

-- === 9. La identificación prueba el camino barato primero ===================
-- Orden nuevo: huella conocida -> resolver determinista -> modelo.
-- `requiere_inferencia` sigue significando lo mismo para n8n, solo que ahora
-- se prende muchísimo menos.
CREATE OR REPLACE FUNCTION ingesta_identificar_tabular(p_documento_id bigint,
                                                       p_columnas text[],
                                                       p_muestra  jsonb DEFAULT '[]'::jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_huella  text := ingesta_huella(p_columnas);
    v_formato text;
    v_sql     jsonb;
    v_reg     jsonb;
BEGIN
    IF v_huella IS NULL THEN
        RETURN ingesta_marcar_error(p_documento_id,
                 'el archivo no tiene cabeceras legibles')
               || jsonb_build_object('requiere_inferencia', false);
    END IF;

    -- (a) Ya la conocemos: cero trabajo.
    SELECT codigo INTO v_formato FROM formatos_documento
    WHERE activo AND clase = 'tabular' AND huella = v_huella;

    IF v_formato IS NOT NULL THEN
        UPDATE documentos SET formato_codigo = v_formato WHERE id = p_documento_id;
        RETURN jsonb_build_object('documento_id', p_documento_id,
                                  'formato', v_formato, 'huella', v_huella,
                                  'origen', 'cache',
                                  'requiere_inferencia', false);
    END IF;

    -- (b) Huella nueva: el diccionario antes que el modelo.
    v_sql := ingesta_inferir_mapeo_sql(p_documento_id, p_columnas, p_muestra);

    IF coalesce((v_sql ->> 'resuelto')::boolean, false) THEN
        v_reg := ingesta_registrar_formato_resuelto(p_documento_id, p_columnas, v_sql);
        RETURN v_reg || jsonb_build_object('huella', v_huella,
                                           'mapeo', v_sql,
                                           'requiere_inferencia', false);
    END IF;

    -- (c) Recién acá se gasta una llamada.
    RETURN jsonb_build_object('documento_id', p_documento_id, 'huella', v_huella,
                              'columnas', to_jsonb(p_columnas),
                              'motivo_inferencia', v_sql ->> 'motivo',
                              'requiere_inferencia', true);
END;
$$;

-- === 10. La compuerta de agregados vale también para el modelo ==============
-- Si el diccionario no alcanzó y contestó el modelo, el mapeo pasa por la
-- MISMA regla. Que la 073 exista no puede depender de qué camino se tomó.
CREATE OR REPLACE FUNCTION ingesta_registrar_formato_inferido(
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
    v_agregado boolean;
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

    v_agregado := ingesta_es_agregado(v_limpio);

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
              'agregado',      v_agregado,
              'columnas',      v_limpio),
            'tabular', v_huella, 'inferido')
    ON CONFLICT (codigo) DO UPDATE SET mapeo = EXCLUDED.mapeo
    RETURNING codigo INTO v_codigo;

    UPDATE documentos SET formato_codigo = v_codigo WHERE id = p_documento_id;

    RETURN jsonb_build_object('documento_id', p_documento_id, 'formato', v_codigo,
                              'huella', v_huella, 'columnas_mapeadas', v_limpio,
                              'agregado', v_agregado, 'origen', 'modelo',
                              'nuevo', true);
END;
$$;

-- === 11. Cargar un agregado no inserta nada =================================
-- Se rechaza en la puerta de `ingesta_cargar_tabular`, que es por donde pasan
-- los dos caminos. El documento queda en 'error' con un motivo que explica QUÉ
-- pasó, no que el archivo esté mal: el archivo está bien, es un resumen, y el
-- detalle que hace falta ya vino en los otros. El panel de la 071 lo nombra.
-- Primero se clona el cuerpo original con otro nombre, y RECIÉN DESPUÉS se
-- reemplaza el original por el envoltorio. Al revés no funciona: el REPLACE ya
-- habría pisado el cuerpo que queremos copiar.
--
-- Se copia de pg_proc en vez de transcribirlo: transcribir 80 líneas de SQL a
-- mano es cómo se introducen los bugs que esta migración vino a sacar.
DO $mig$
DECLARE
    v_src text;
BEGIN
    SELECT prosrc INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'ingesta_cargar_tabular'
      AND pg_get_function_identity_arguments(p.oid) = 'p_documento_id bigint, p_filas jsonb'
      AND prosrc LIKE '%v_max_nulos%';   -- el cuerpo viejo, no el envoltorio nuevo

    IF v_src IS NULL THEN
        RAISE EXCEPTION '073: no encontré el cuerpo original de ingesta_cargar_tabular';
    END IF;

    EXECUTE format(
      'CREATE FUNCTION ingesta_cargar_tabular_detalle(p_documento_id bigint, '
      'p_filas jsonb) RETURNS jsonb LANGUAGE plpgsql AS %L', v_src);
END;
$mig$;

CREATE OR REPLACE FUNCTION ingesta_cargar_tabular(p_documento_id bigint, p_filas jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_mapeo jsonb;
BEGIN
    SELECT f.mapeo INTO v_mapeo
    FROM documentos d JOIN formatos_documento f ON f.codigo = d.formato_codigo
    WHERE d.id = p_documento_id;

    IF coalesce((v_mapeo ->> 'agregado')::boolean, false) THEN
        RETURN ingesta_marcar_error(p_documento_id,
                 'es un resumen (totales por día, sin producto ni cantidad), '
                 'no un detalle de movimientos: sumarlo contaría dos veces lo '
                 'que ya traen los archivos de detalle')
               || jsonb_build_object('agregado', true);
    END IF;

    RETURN ingesta_cargar_tabular_detalle(p_documento_id, p_filas);
END;
$$;

-- === 12. Reparar lo que el modelo ya había aprendido mal =====================
-- `tabular_20a6271e84` es el cierre de caja: fecha + Total_Ventas, sin producto
-- ni cantidad. Se marca como agregado y se borran los movimientos que metió,
-- que son exactamente los que inflaban las ventas.
UPDATE formatos_documento
SET mapeo = mapeo || jsonb_build_object('agregado', true)
WHERE clase = 'tabular'
  AND coalesce((mapeo ->> 'agregado')::boolean, false) IS NOT TRUE
  AND ingesta_es_agregado(mapeo -> 'columnas');

DELETE FROM movimientos m
USING documentos d JOIN formatos_documento f ON f.codigo = d.formato_codigo
WHERE m.documento_id = d.id
  AND coalesce((f.mapeo ->> 'agregado')::boolean, false);

UPDATE documentos d
SET estado = 'error',
    error  = 'es un resumen (totales por día, sin producto ni cantidad), no un '
             'detalle de movimientos: sumarlo contaría dos veces lo que ya traen '
             'los archivos de detalle'
FROM formatos_documento f
WHERE f.codigo = d.formato_codigo
  AND coalesce((f.mapeo ->> 'agregado')::boolean, false)
  AND d.estado = 'parseado';

-- === 13. El prompt del modelo queda para lo que el diccionario no cubre =====
-- Sigue existiendo y sigue siendo el mismo, pero ahora se invoca solo cuando
-- falta la fecha o el valor. Se le baja el cupo: sin las columnas fáciles que
-- resolver de más, el JSON de respuesta es corto.
UPDATE prompts_tecnicos SET max_tokens = 2000
WHERE clave = 'ingesta.inferir_mapeo';

NOTIFY pgrst, 'reload schema';
