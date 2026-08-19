CREATE OR REPLACE VIEW public.v_calidad_matching AS
 SELECT n.id AS negocio_id,
    count(a.id) AS aliases,
    count(a.id) FILTER (WHERE a.producto_id IS NOT NULL) AS resueltos,
    count(a.id) FILTER (WHERE a.producto_id IS NULL) AS pendientes,
    count(a.id) FILTER (WHERE a.origen = 'trigram'::origen_alias) AS por_trigram,
    count(a.id) FILTER (WHERE a.origen = 'manual'::origen_alias) AS confirmados_manual,
    round(100.0 * count(a.id) FILTER (WHERE a.producto_id IS NOT NULL)::numeric / NULLIF(count(a.id), 0)::numeric, 1) AS pct_resuelto,
    m.movs_sin_producto,
    m.dinero_sin_producto,
    m.pct_dinero_fuera
   FROM negocios n
     LEFT JOIN alias a ON a.negocio_id = n.id
     CROSS JOIN LATERAL ( SELECT count(*) FILTER (WHERE v.producto_id IS NULL) AS movs_sin_producto,
            round(COALESCE(sum(v.valor_total) FILTER (WHERE v.producto_id IS NULL), 0::numeric)) AS dinero_sin_producto,
            round(100.0 * COALESCE(sum(v.valor_total) FILTER (WHERE v.producto_id IS NULL), 0::numeric) / NULLIF(sum(v.valor_total), 0::numeric), 1) AS pct_dinero_fuera
           FROM mov_visibles v
          WHERE v.negocio_id = n.id) m
  GROUP BY n.id, m.movs_sin_producto, m.dinero_sin_producto, m.pct_dinero_fuera;
