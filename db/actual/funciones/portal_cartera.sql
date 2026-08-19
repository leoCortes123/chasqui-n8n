CREATE OR REPLACE FUNCTION public.portal_cartera()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    RETURN jsonb_build_object(
      -- Las dos cifras grandes: cuánto me deben y cuánto debo, y de eso
      -- cuánto ya está vencido.
      'resumen', (
        SELECT jsonb_build_object(
                 'por_cobrar', coalesce(sum(saldo) FILTER (WHERE tipo = 'venta'),  0),
                 'por_pagar',  coalesce(sum(saldo) FILTER (WHERE tipo = 'compra'), 0),
                 'vencido_cobrar', coalesce(sum(saldo) FILTER
                   (WHERE tipo = 'venta'  AND vencimiento < current_date), 0),
                 'vencido_pagar',  coalesce(sum(saldo) FILTER
                   (WHERE tipo = 'compra' AND vencimiento < current_date), 0))
        FROM facturas WHERE negocio_id = v_negocio AND saldo > 0),

      'edades', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
                 'tipo', e.tipo, 'edad', e.edad,
                 'facturas', e.facturas, 'saldo', e.saldo))
        FROM v_cartera_edades e WHERE e.negocio_id = v_negocio), '[]'::jsonb),

      'terceros', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
                 'tercero_id', t.tercero_id, 'nombre', t.nombre, 'nit', t.nit,
                 'tipo', t.tipo, 'facturas', t.facturas, 'saldo', t.saldo,
                 'dias_mora', t.dias_mora)
               ORDER BY t.saldo DESC)
        FROM v_cartera_tercero t WHERE t.negocio_id = v_negocio), '[]'::jsonb),

      -- Las facturas abiertas, la más urgente primero (sin vencimiento al
      -- final: no se le puede cobrar mora a lo que no tiene fecha).
      'facturas', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
                 'id', f.id, 'tipo', f.tipo, 'numero', f.numero,
                 'tercero', t.nombre, 'emision', f.emision,
                 'vencimiento', f.vencimiento, 'total', f.total,
                 'saldo', f.saldo,
                 'dias_mora', CASE WHEN f.vencimiento < current_date
                                   THEN current_date - f.vencimiento END)
               ORDER BY f.vencimiento ASC NULLS LAST, f.id)
        FROM facturas f LEFT JOIN terceros t ON t.id = f.tercero_id
        WHERE f.negocio_id = v_negocio AND f.saldo > 0), '[]'::jsonb));
END;
$function$
