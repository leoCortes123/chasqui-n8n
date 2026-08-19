-- 019_ingesta_encadenado.sql — dos arreglos que salen de encadenar la ingesta
-- nueva en wf_ingesta.

-- 1. No pisar un error ya diagnosticado.
-- La cadena es registrar -> identificar -> (inferir) -> cargar. Cada paso puede
-- fallar con un mensaje específico ("no sé leer archivos docx", "el archivo no
-- tiene cabeceras legibles"), pero el paso siguiente corría igual y lo
-- sobreescribía con uno genérico. El primer diagnóstico es el bueno: es el que
-- sabe por qué falló.
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
    v_estado     estado_doc;
    v_error      text;
    v_n          int;
    v_sin_fecha  int;
    v_sin_valor  int;
    v_pct_fecha  numeric;
    v_pct_valor  numeric;
BEGIN
    SELECT d.estado, d.error, d.negocio_id, f.mapeo
      INTO v_estado, v_error, v_negocio_id, v_mapeo
    FROM documentos d
    LEFT JOIN formatos_documento f ON f.codigo = d.formato_codigo
    WHERE d.id = p_documento_id;

    -- Ya venía marcado en error por un paso anterior: se respeta el motivo.
    IF v_estado = 'error' THEN
        RETURN jsonb_build_object('documento_id', p_documento_id,
                                  'estado', 'error', 'error', v_error);
    END IF;

    IF v_mapeo IS NULL THEN
        RETURN ingesta_marcar_error(p_documento_id, 'el documento no tiene formato asignado');
    END IF;

    v_cols      := v_mapeo -> 'columnas';
    v_tipo      := coalesce(v_mapeo ->> 'tipo', 'venta');
    v_dec       := coalesce(v_mapeo ->> 'decimal', '.');
    v_mil       := coalesce(v_mapeo ->> 'miles', '');
    v_fmt       := v_mapeo ->> 'formato_fecha';
    v_max_nulos := coalesce((v_mapeo ->> 'max_pct_nulos')::numeric, 20);

    WITH norm AS (
        SELECT ingesta_fecha(r -> (v_cols ->> 'fecha'), v_fmt)                  AS fecha,
               ingesta_num  (r -> (v_cols ->> 'cantidad'),       v_dec, v_mil)  AS cantidad,
               ingesta_num  (r -> (v_cols ->> 'valor_unitario'), v_dec, v_mil)  AS valor_unitario,
               ingesta_num  (r -> (v_cols ->> 'valor_total'),    v_dec, v_mil)  AS valor_total,
               r || jsonb_strip_nulls(jsonb_build_object(
                      'producto',  r ->> (v_cols ->> 'producto'),
                      'categoria', r ->> (v_cols ->> 'categoria'),
                      'codigo',    r ->> (v_cols ->> 'codigo'),
                      'unidad',    r ->> (v_cols ->> 'unidad')))                AS raw
        FROM jsonb_array_elements(coalesce(p_filas, '[]'::jsonb)) AS r
    ),
    medida AS (
        SELECT count(*)::int                                          AS n,
               count(*) FILTER (WHERE fecha IS NULL)::int             AS sin_fecha,
               count(*) FILTER (WHERE valor_total IS NULL
                                  AND valor_unitario IS NULL)::int    AS sin_valor
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

-- 2. ejecucion_cerrar devuelve a quién hay que entregarle el informe.
-- wf_ejecutar armaba respuestas[] sin chat_id y wf_enviar terminaba corriendo
-- `SELECT (undefined)::bigint`: el informe se generaba y nunca se entregaba.
-- El dato ya está en la base (ejecución -> sesión -> usuario), así que sale de
-- acá y no de un nodo, y sirve igual cuando la ejecución no vino de un chat.
-- Cuerpo idéntico al de 008; lo único nuevo es resolver el chat y devolverlo
-- junto con el servicio, para que wf_ejecutar no tenga que adivinarlos.
CREATE OR REPLACE FUNCTION ejecucion_cerrar(p_ejecucion_id bigint, p_estado text,
                                            p_resultado jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_sesion_id bigint;
    v_chat      bigint;
    v_servicio  text;
BEGIN
    UPDATE ejecuciones SET
        estado        = p_estado::estado_ejec,
        texto         = coalesce(p_resultado ->> 'texto', texto),
        tokens_prompt = coalesce((p_resultado ->> 'tokens_prompt')::int, tokens_prompt),
        tokens_salida = coalesce((p_resultado ->> 'tokens_salida')::int, tokens_salida),
        costo         = coalesce((p_resultado ->> 'costo')::numeric, costo),
        pdf           = coalesce(decode(p_resultado ->> 'pdf_base64', 'base64'), pdf),
        error         = p_resultado ->> 'error',
        fin           = now()
    WHERE id = p_ejecucion_id
    RETURNING sesion_id, servicio_codigo INTO v_sesion_id, v_servicio;

    -- Cierra la sesión asociada según el desenlace.
    IF v_sesion_id IS NOT NULL THEN
        SELECT u.telegram_chat_id INTO v_chat
        FROM sesiones s JOIN usuarios u ON u.id = s.usuario_id
        WHERE s.id = v_sesion_id;

        UPDATE sesiones SET
            estado     = CASE WHEN p_estado = 'completada' THEN 'completada'::estado_sesion
                              ELSE 'fallida'::estado_sesion END,
            cerrada_en = now()
        WHERE id = v_sesion_id;
    END IF;

    RETURN jsonb_build_object('ejecucion_id', p_ejecucion_id, 'estado', p_estado,
                              'chat_id', v_chat, 'servicio_codigo', v_servicio);
END;
$$;
