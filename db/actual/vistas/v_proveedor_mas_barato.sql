CREATE OR REPLACE VIEW public.v_proveedor_mas_barato AS
 SELECT DISTINCT ON (negocio_id, producto_id) negocio_id,
    producto_id,
    proveedor,
    round(precio_prom) AS precio,
    compras,
    ultima_compra
   FROM ( SELECT m.negocio_id,
            m.producto_id,
            NULLIF(btrim(COALESCE(m.raw ->> 'proveedor'::text, ''::text)), ''::text) AS proveedor,
            sum(m.valor_total) / NULLIF(sum(m.cantidad), 0::numeric) AS precio_prom,
            count(*) AS compras,
            max(m.fecha) AS ultima_compra
           FROM mov_visibles m
          WHERE m.tipo = 'compra'::tipo_movimiento AND m.producto_id IS NOT NULL AND m.cantidad > 0::numeric AND m.valor_total > 0::numeric AND NULLIF(btrim(COALESCE(m.raw ->> 'proveedor'::text, ''::text)), ''::text) IS NOT NULL
          GROUP BY m.negocio_id, m.producto_id, (NULLIF(btrim(COALESCE(m.raw ->> 'proveedor'::text, ''::text)), ''::text))) s
  ORDER BY negocio_id, producto_id, precio_prom, ultima_compra DESC;
