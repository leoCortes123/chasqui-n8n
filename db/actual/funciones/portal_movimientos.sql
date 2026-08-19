CREATE OR REPLACE FUNCTION public.portal_movimientos(p_tipo text DEFAULT NULL::text, p_limite integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    -- Un tipo desconocido no revienta el fetch: se ignora el filtro.
    IF p_tipo IS NOT NULL AND p_tipo NOT IN ('compra', 'venta', 'ajuste') THEN
        p_tipo := NULL;
    END IF;

    RETURN coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', m.id, 'tipo', m.tipo, 'fecha', m.fecha,
               'nombre', coalesce(p.nombre_canonico,
                                  portal_mov_nombre(m.raw, f.mapeo)),
               'tercero', m.raw ->> 'proveedor',
               'cantidad', m.cantidad,
               'valor_unitario', m.valor_unitario,
               'valor_total', m.valor_total)
             ORDER BY m.fecha DESC NULLS LAST, m.id DESC)
      FROM (SELECT * FROM movimientos
            WHERE negocio_id = v_negocio
              AND (p_tipo IS NULL OR tipo = p_tipo::tipo_movimiento)
            ORDER BY fecha DESC NULLS LAST, id DESC
            LIMIT greatest(coalesce(p_limite, 50), 1)) m
      LEFT JOIN productos p ON p.id = m.producto_id
      LEFT JOIN documentos d ON d.id = m.documento_id
      LEFT JOIN formatos_documento f ON f.codigo = d.formato_codigo), '[]'::jsonb);
END;
$function$
