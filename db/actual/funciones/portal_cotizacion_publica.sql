CREATE OR REPLACE FUNCTION public.portal_cotizacion_publica(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_out jsonb;
BEGIN
    SELECT jsonb_build_object(
             'ok', true,
             'negocio', jsonb_build_object('nombre', n.nombre, 'nit', n.nit,
                                           'tipo', n.tipo),
             'cliente', c.cliente, 'notas', c.notas, 'items', c.items,
             'total', c.total, 'creado_en', c.creado_en,
             'vigente_hasta', c.vigente_hasta,
             'vencida', c.vigente_hasta IS NOT NULL AND c.vigente_hasta < current_date)
      INTO v_out
    FROM cotizaciones c JOIN negocios n ON n.id = c.negocio_id
    WHERE c.token = coalesce(p_token, '') AND c.estado = 'abierta';

    RETURN coalesce(v_out, jsonb_build_object('ok', false, 'error', 'no_existe'));
END;
$function$
