CREATE OR REPLACE FUNCTION public.portal_movimientos_resumen()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    RETURN jsonb_build_object(
      'mes_actual', (
        SELECT jsonb_build_object(
                 'ventas',  coalesce(sum(valor_total) FILTER (WHERE tipo = 'venta'),  0),
                 'compras', coalesce(sum(valor_total) FILTER (WHERE tipo = 'compra'), 0),
                 'movimientos', count(*))
        FROM movimientos
        WHERE negocio_id = v_negocio
          -- acotado por los dos lados: un archivo con fechas futuras (pasa, y
          -- los fixtures lo prueban) no debe inflar "este mes"
          AND fecha >= date_trunc('month', current_date)
          AND fecha <  date_trunc('month', current_date) + interval '1 month'),

      'meses', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
                 'mes', to_char(m.mes, 'YYYY-MM'),
                 'ventas', m.ventas, 'compras', m.compras,
                 'movimientos', m.n)
               ORDER BY m.mes DESC)
        FROM (SELECT date_trunc('month', fecha) AS mes,
                     coalesce(sum(valor_total) FILTER (WHERE tipo = 'venta'),  0) AS ventas,
                     coalesce(sum(valor_total) FILTER (WHERE tipo = 'compra'), 0) AS compras,
                     count(*) AS n
              FROM movimientos
              WHERE negocio_id = v_negocio AND fecha IS NOT NULL
              GROUP BY 1 ORDER BY 1 DESC LIMIT 12) m), '[]'::jsonb),

      -- Histórico completo a propósito: con pocos datos, un recorte de 90 días
      -- deja la pantalla vacía y parece que el sistema no sirve.
      -- Se agrupa por norm_texto: mientras matching no resuelva todas las
      -- líneas, "HUEVOS AA X30" (crudo) y "Huevos AA x30" (canónico) son el
      -- mismo producto y no deben salir dos veces. Para mostrar se prefiere el
      -- nombre canónico si alguna fila lo tiene.
      'top_productos', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
                 'nombre', t.nombre, 'cantidad', t.cantidad, 'total', t.total)
               ORDER BY t.total DESC NULLS LAST)
        FROM (SELECT coalesce(max(b.nombre) FILTER (WHERE b.canonico),
                              max(b.nombre)) AS nombre,
                     sum(b.cantidad) AS cantidad, sum(b.total) AS total
              FROM (SELECT coalesce(p.nombre_canonico,
                                    portal_mov_nombre(m.raw, f.mapeo),
                                    '(sin nombre)') AS nombre,
                           p.id IS NOT NULL AS canonico,
                           m.cantidad, m.valor_total AS total
                    FROM movimientos m
                    LEFT JOIN productos p ON p.id = m.producto_id
                    LEFT JOIN documentos d ON d.id = m.documento_id
                    LEFT JOIN formatos_documento f ON f.codigo = d.formato_codigo
                    WHERE m.negocio_id = v_negocio AND m.tipo = 'venta') b
              GROUP BY norm_texto(b.nombre)
              ORDER BY 3 DESC NULLS LAST LIMIT 8) t), '[]'::jsonb));
END;
$function$
