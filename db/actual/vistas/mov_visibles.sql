CREATE OR REPLACE VIEW public.mov_visibles AS
 SELECT id,
    negocio_id,
    documento_id,
    tipo,
    fecha,
    producto_id,
    alias_id,
    cantidad,
    valor_unitario,
    valor_total,
    impuesto,
    raw,
    creado_en,
    tercero_id
   FROM movimientos m
  WHERE fecha IS NULL OR plan_desde(negocio_id) IS NULL OR fecha >= plan_desde(negocio_id);
