CREATE OR REPLACE VIEW public.v_cartera_tercero AS
 SELECT f.negocio_id,
    f.tipo,
    t.id AS tercero_id,
    t.nombre,
    t.nit,
    count(*) AS facturas,
    sum(f.saldo) AS saldo,
    min(f.vencimiento) AS vencimiento_mas_antiguo,
    max(CURRENT_DATE - f.vencimiento) FILTER (WHERE f.vencimiento < CURRENT_DATE) AS dias_mora
   FROM facturas f
     JOIN terceros t ON t.id = f.tercero_id
  WHERE f.saldo > 0::numeric
  GROUP BY f.negocio_id, f.tipo, t.id, t.nombre, t.nit;
