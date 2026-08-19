CREATE OR REPLACE FUNCTION public.ingesta_cargar_tabular_detalle(p_documento_id bigint, p_filas jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
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
$function$
