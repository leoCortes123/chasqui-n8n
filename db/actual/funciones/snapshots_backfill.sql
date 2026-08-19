CREATE OR REPLACE FUNCTION public.snapshots_backfill()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_n int := 0;
    r   record;
BEGIN
    FOR r IN
        -- Una ejecución por negocio y día: la última completada de cada día.
        SELECT DISTINCT ON (e.negocio_id, e.inicio::date)
               e.id, e.negocio_id, e.inicio::date AS fecha, e.hallazgos AS h
        FROM ejecuciones e
        JOIN servicios s ON s.codigo = e.servicio_codigo AND s.entrada = 'archivos'
        WHERE e.estado = 'completada'
          AND jsonb_typeof(e.hallazgos) = 'object'
          AND e.hallazgos ? 'periodo'
        ORDER BY e.negocio_id, e.inicio::date, e.id DESC
    LOOP
        INSERT INTO snapshots_negocio (negocio_id, fecha, version, periodo, salud,
                                       metricas, origen, ejecucion_id)
        SELECT r.negocio_id, r.fecha, snapshot_version(),
               CASE WHEN (r.h #>> '{periodo,desde}') IS NOT NULL
                    THEN daterange((r.h #>> '{periodo,desde}')::date,
                                   (r.h #>> '{periodo,hasta}')::date, '[]') END,
               r.h -> 'salud',
               jsonb_build_object(
                 'parcial', true,
                 'reconstruido_de', 'ejecuciones.hallazgos',
                 -- Lo que NO se puede reconstruir, dicho explícitamente para que
                 -- B3 no lo confunda con "estaba en cero". `totales` figura
                 -- porque solo se recuperan los conteos de movimientos: los
                 -- importes y `base_mes` nunca estuvieron en los hallazgos.
                 'faltan', jsonb_build_array('totales.ventas', 'totales.compras',
                                             'totales.base_mes', 'margenes',
                                             'coberturas', 'proveedores',
                                             'precios_proveedor', 'ventas_producto',
                                             'pareto', 'calidad', 'umbrales'),
                 -- Lo que sí se recupera se escribe con LA FORMA DEL CONTRATO,
                 -- no con la que tenía en los hallazgos. Un snapshot parcial es
                 -- un snapshot con huecos, no un snapshot con otro esquema: si
                 -- no, B3 tendría que saber leer las dos formas.
                 'totales', jsonb_build_object(
                    'movimientos_venta',  r.h #> '{periodo,movimientos_venta}',
                    'movimientos_compra', r.h #> '{periodo,movimientos_compra}'),
                 'productos', jsonb_build_object(
                    'total',               r.h #> '{resumen,productos}',
                    'con_precio',          r.h #> '{resumen,con_precio}',
                    'margen_promedio_pct', r.h #> '{resumen,margen_promedio_pct}'),
                 -- Estos NO se pueden llevar al contrato: los hallazgos guardan
                 -- el nombre del producto y no su id, así que no son emparejables
                 -- con los de un snapshot real. Van con nombre propio para que
                 -- nadie los confunda con las claves de v1.
                 'pareto_parcial',         coalesce(r.h -> 'pareto', '[]'::jsonb),
                 'margen_bajo_parcial',    coalesce(r.h -> 'margen_bajo', '[]'::jsonb),
                 'derivas_parcial',        coalesce(r.h -> 'deriva_costo', '[]'::jsonb),
                 'baja_cobertura_parcial', coalesce(r.h -> 'baja_cobertura', '[]'::jsonb)),
               'backfill', r.id
        ON CONFLICT ON CONSTRAINT uq_snapshot_dia DO NOTHING;

        v_n := v_n + (CASE WHEN FOUND THEN 1 ELSE 0 END);
    END LOOP;

    RETURN v_n;
END;
$function$
