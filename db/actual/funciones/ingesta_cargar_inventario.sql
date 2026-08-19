CREATE OR REPLACE FUNCTION public.ingesta_cargar_inventario(p_documento_id bigint, p_filas jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_negocio_id bigint;
    v_mapeo      jsonb;
    v_cols       jsonb;
    v_dec        text;
    v_mil        text;
    v_fmt        text;
    v_estado     estado_doc;
    v_error      text;
    v_n          int := 0;
    v_sin_prod   int := 0;
BEGIN
    SELECT d.estado, d.error, d.negocio_id, f.mapeo
      INTO v_estado, v_error, v_negocio_id, v_mapeo
    FROM documentos d
    LEFT JOIN formatos_documento f ON f.codigo = d.formato_codigo
    WHERE d.id = p_documento_id;

    IF v_estado = 'error' THEN
        RETURN jsonb_build_object('documento_id', p_documento_id,
                                  'estado', 'error', 'error', v_error);
    END IF;
    IF v_mapeo IS NULL THEN
        RETURN ingesta_marcar_error(p_documento_id, 'el documento no tiene formato asignado');
    END IF;

    v_cols := v_mapeo -> 'columnas';
    v_dec  := coalesce(v_mapeo ->> 'decimal', '.');
    v_mil  := coalesce(v_mapeo ->> 'miles', '');
    v_fmt  := v_mapeo ->> 'formato_fecha';

    WITH filas AS (
        SELECT ingesta_fecha(r -> (v_cols ->> 'fecha'), v_fmt)                 AS fecha,
               btrim(coalesce(r ->> (v_cols ->> 'producto'), ''))              AS producto_txt,
               ingesta_num  (r -> (v_cols ->> 'unidades'), v_dec, v_mil)       AS unidades
        FROM jsonb_array_elements(coalesce(p_filas, '[]'::jsonb)) AS r
    ),
    resueltas AS (
        -- Un conteo sin fecha legible es un conteo de hoy: es lo que acaba de
        -- hacer quien mandó el archivo. Pero `to_date` es indulgente y con un
        -- patrón mal declarado devuelve basura en vez de fallar (14/08/2026 con
        -- 'YYYY-MM-DD' da 2008-01-01), así que lo absurdo se descarta antes de
        -- caer al default en vez de guardarse como si fuera un dato.
        SELECT coalesce(CASE WHEN fecha BETWEEN date '2000-01-01' AND current_date + 1
                             THEN fecha END, current_date) AS fecha,
               producto_txt, unidades,
               (match_resolver_producto(v_negocio_id, producto_txt) ->> 'producto_id')::bigint AS producto_id
        FROM filas
        WHERE nullif(producto_txt, '') IS NOT NULL AND unidades IS NOT NULL
    ),
    ins AS (
        INSERT INTO conteos_inventario
               (negocio_id, producto_id, fecha, unidades, origen, documento_id)
        SELECT v_negocio_id, producto_id, fecha, unidades, 'archivo', p_documento_id
        FROM resueltas WHERE producto_id IS NOT NULL
        ON CONFLICT (negocio_id, producto_id, fecha)
          DO UPDATE SET unidades = EXCLUDED.unidades,
                        origen   = EXCLUDED.origen,
                        documento_id = EXCLUDED.documento_id
        RETURNING 1
    )
    SELECT (SELECT count(*) FROM ins),
           (SELECT count(*) FROM resueltas WHERE producto_id IS NULL)
      INTO v_n, v_sin_prod;

    UPDATE documentos SET estado = 'parseado', error = NULL WHERE id = p_documento_id;

    RETURN jsonb_build_object('documento_id', p_documento_id, 'estado', 'parseado',
                              'clase', 'inventario', 'conteos', v_n,
                              'sin_producto', v_sin_prod);
END;
$function$
