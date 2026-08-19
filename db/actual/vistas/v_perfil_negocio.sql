CREATE OR REPLACE VIEW public.v_perfil_negocio AS
 SELECT id AS negocio_id,
    nombre,
    plan,
    tipo AS tipo_codigo,
    ( SELECT tipos_negocio.nombre
           FROM tipos_negocio
          WHERE tipos_negocio.codigo = n.tipo) AS tipo_nombre,
    NULLIF(btrim(COALESCE(nit, ''::text)), ''::text) IS NOT NULL AS tiene_nit,
    ( SELECT jsonb_build_object('desde', min(mov_visibles.fecha), 'hasta', max(mov_visibles.fecha), 'meses', round(GREATEST((max(mov_visibles.fecha) - min(mov_visibles.fecha))::numeric / 30.0, 0::numeric), 1), 'movimientos', count(*), 'ventas', round(COALESCE(sum(mov_visibles.valor_total) FILTER (WHERE mov_visibles.tipo = 'venta'::tipo_movimiento), 0::numeric)), 'compras', round(COALESCE(sum(mov_visibles.valor_total) FILTER (WHERE mov_visibles.tipo = 'compra'::tipo_movimiento), 0::numeric))) AS jsonb_build_object
           FROM mov_visibles
          WHERE mov_visibles.negocio_id = n.id) AS periodo,
    ( SELECT jsonb_build_object('total', count(*), 'con_precio', count(*) FILTER (WHERE v_margen_producto.precio_actual IS NOT NULL), 'margen_mediano_pct', round(percentile_cont(0.5::double precision) WITHIN GROUP (ORDER BY (v_margen_producto.margen_pct::double precision))::numeric, 2), 'margen_min_pct', round(min(v_margen_producto.margen_pct), 2), 'margen_max_pct', round(max(v_margen_producto.margen_pct), 2)) AS jsonb_build_object
           FROM v_margen_producto
          WHERE v_margen_producto.negocio_id = n.id) AS productos,
    ( SELECT COALESCE(jsonb_agg(jsonb_build_object('producto_id', pa.producto_id, 'nombre', p.nombre_canonico, 'utilidad', round(pa.utilidad), 'pct_utilidad', pa.pct_utilidad) ORDER BY pa.utilidad DESC), '[]'::jsonb) AS "coalesce"
           FROM v_pareto_utilidad pa
             JOIN productos p ON p.id = pa.producto_id
          WHERE pa.negocio_id = n.id AND pa.pct_acumulado <= 80::numeric) AS top_productos,
    ( SELECT jsonb_build_object('total', count(*), 'principal', (array_agg(g.prov ORDER BY g.gasto DESC))[1], 'concentracion_pct', round(max(g.gasto) * 100.0 / NULLIF(sum(g.gasto), 0::numeric), 1), 'detalle', COALESCE(jsonb_agg(jsonb_build_object('proveedor', g.prov, 'gasto', round(g.gasto)) ORDER BY g.gasto DESC), '[]'::jsonb)) AS jsonb_build_object
           FROM ( SELECT NULLIF(btrim(COALESCE(mov_visibles.raw ->> 'proveedor'::text, ''::text)), ''::text) AS prov,
                    sum(mov_visibles.valor_total) AS gasto
                   FROM mov_visibles
                  WHERE mov_visibles.negocio_id = n.id AND mov_visibles.tipo = 'compra'::tipo_movimiento AND NULLIF(btrim(COALESCE(mov_visibles.raw ->> 'proveedor'::text, ''::text)), ''::text) IS NOT NULL
                  GROUP BY (NULLIF(btrim(COALESCE(mov_visibles.raw ->> 'proveedor'::text, ''::text)), ''::text))) g) AS proveedores,
    ( SELECT jsonb_build_object('suficiente', (max(mov_visibles.fecha) - min(mov_visibles.fecha)) >= 365, 'por_mes', COALESCE(( SELECT jsonb_agg(jsonb_build_object('mes', s.m, 'ventas', round(s.v), 'meses_observados', s.obs) ORDER BY s.m) AS jsonb_agg
                   FROM ( SELECT EXTRACT(month FROM mov_visibles_1.fecha)::integer AS m,
                            sum(mov_visibles_1.valor_total) AS v,
                            count(DISTINCT date_trunc('month'::text, mov_visibles_1.fecha::timestamp with time zone)) AS obs
                           FROM mov_visibles mov_visibles_1
                          WHERE mov_visibles_1.negocio_id = n.id AND mov_visibles_1.tipo = 'venta'::tipo_movimiento AND mov_visibles_1.fecha IS NOT NULL
                          GROUP BY (EXTRACT(month FROM mov_visibles_1.fecha)::integer)) s), '[]'::jsonb)) AS jsonb_build_object
           FROM mov_visibles
          WHERE mov_visibles.negocio_id = n.id AND mov_visibles.fecha IS NOT NULL) AS estacionalidad,
    ( SELECT COALESCE(jsonb_agg(jsonb_build_object('regla', r.regla, 'veces', r.veces, 'abiertas', r.abiertas, 'resueltas', r.resueltas, 'primera_vez', r.primera) ORDER BY r.veces DESC), '[]'::jsonb) AS "coalesce"
           FROM ( SELECT recomendaciones.regla,
                    count(*) AS veces,
                    count(*) FILTER (WHERE recomendaciones.estado = ANY (ARRAY['nueva'::text, 'vigente'::text])) AS abiertas,
                    count(*) FILTER (WHERE recomendaciones.estado = 'resuelta'::text) AS resueltas,
                    min(recomendaciones.detectada_en)::date AS primera
                   FROM recomendaciones
                  WHERE recomendaciones.negocio_id = n.id
                  GROUP BY recomendaciones.regla) r) AS problemas_recurrentes,
    ( SELECT jsonb_build_object('cerradas_total', count(*) FILTER (WHERE recomendaciones.estado <> ALL (ARRAY['nueva'::text, 'vigente'::text])), 'por_dato', count(*) FILTER (WHERE recomendaciones.cerrada_por = 'dato'::text), 'por_accion', count(*) FILTER (WHERE recomendaciones.cerrada_por = 'accion_usuario'::text), 'ignoradas', count(*) FILTER (WHERE recomendaciones.estado = 'ignorada'::text), 'sin_datos', count(*) FILTER (WHERE recomendaciones.cerrada_por = 'sin_datos'::text)) AS jsonb_build_object
           FROM recomendaciones
          WHERE recomendaciones.negocio_id = n.id) AS acciones,
    ( SELECT jsonb_build_object('snapshots', count(*), 'ultimo', max(snapshots_negocio.fecha), 'serie', COALESCE(( SELECT jsonb_agg(jsonb_build_object('fecha', u.fecha, 'indice', u.salud -> 'indice'::text) ORDER BY u.fecha) AS jsonb_agg
                   FROM ( SELECT snapshots_negocio_1.fecha,
                            snapshots_negocio_1.salud
                           FROM snapshots_negocio snapshots_negocio_1
                          WHERE snapshots_negocio_1.negocio_id = n.id
                          ORDER BY snapshots_negocio_1.fecha DESC
                         LIMIT 12) u), '[]'::jsonb)) AS jsonb_build_object
           FROM snapshots_negocio
          WHERE snapshots_negocio.negocio_id = n.id) AS salud_historia,
    ( SELECT jsonb_build_object('movs_sin_producto', v_calidad_matching.movs_sin_producto, 'dinero_sin_producto', v_calidad_matching.dinero_sin_producto, 'pct_dinero_fuera', COALESCE(v_calidad_matching.pct_dinero_fuera, 0::numeric), 'productos_stock_estimado', ( SELECT count(*) AS count
                   FROM v_balance_unidades
                  WHERE v_balance_unidades.negocio_id = n.id AND v_balance_unidades.origen_stock = 'estimado'::text)) AS jsonb_build_object
           FROM v_calidad_matching
          WHERE v_calidad_matching.negocio_id = n.id) AS calidad
   FROM negocios n;
