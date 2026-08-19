CREATE OR REPLACE VIEW public.v_conocimiento_cobertura AS
 SELECT n.id AS negocio_id,
    n.nombre AS negocio,
    count(c.id) AS hechos,
    count(c.id) FILTER (WHERE c.tipo = 'precio'::text) AS precios,
    count(c.id) FILTER (WHERE c.origen = 'chat'::text) AS desde_chat,
    ( SELECT count(*) AS count
           FROM conocimiento_pendiente p
          WHERE p.negocio_id = n.id AND p.resuelto_por IS NULL) AS pendientes,
    max(c.actualizado_en) AS ultimo_cambio
   FROM negocios n
     LEFT JOIN conocimiento c ON c.negocio_id = n.id
  GROUP BY n.id, n.nombre;
