-- 035_portal_movimientos.sql — Fase 2, primer paso: la facturación, en el portal.
--
-- Decisión que corrige el plan escrito: la entrega NUNCA es un PDF. Todo lo que
-- muestre información vive en el portal; si algún caso llega a necesitar un
-- documento entregable, se analiza puntual. Por eso acá no aparece Gotenberg:
-- son tres RPC de solo lectura sobre lo que la ingesta ya normalizó en
-- `movimientos` y `documentos`. Cero tablas nuevas.
--
-- Mismas reglas que la 033: SECURITY DEFINER, el negocio_id sale del JWT, nada
-- de GRANTs sobre tablas. La 034 ya revocó el EXECUTE público por defecto, así
-- que estas funciones solo existen para quien reciba el GRANT del final.

-- =============================================================================
-- 1. Resumen: lo primero que ve el dueño al abrir la pestaña
-- =============================================================================
-- 'mes_actual' para las cifras grandes, 'meses' para la serie (hasta 12) y
-- 'top_productos' para saber qué mueve la plata. El nombre del producto sale
-- del canónico si matching ya lo resolvió; si no, de la descripción cruda del
-- documento: mostrar "(sin nombre)" solo cuando ni eso hay.
--
-- El nombre crudo no siempre está en la misma clave: el parser DIAN escribe
-- 'descripcion', el tabular guarda la fila con las cabeceras originales del
-- POS ("Descripcion", "Vr Total", ...). La clave real la conoce el mapeo del
-- formato (columnas->producto), así que se resuelve por ahí.

CREATE OR REPLACE FUNCTION portal_mov_nombre(p_raw jsonb, p_mapeo jsonb)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT coalesce(p_raw ->> 'descripcion',
                    p_raw ->> 'producto',
                    p_raw ->> nullif(p_mapeo #>> '{columnas,producto}', ''));
$$;

CREATE OR REPLACE FUNCTION portal_movimientos_resumen()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
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
$$;

-- =============================================================================
-- 2. El detalle: últimos movimientos, filtrables por tipo
-- =============================================================================

CREATE OR REPLACE FUNCTION portal_movimientos(p_tipo   text DEFAULT NULL,
                                              p_limite int  DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
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
$$;

-- =============================================================================
-- 3. Los archivos: qué subió y qué pasó con cada uno
-- =============================================================================
-- Es la respuesta a "¿le llegó mi factura?" sin abrir n8n: estado, error si lo
-- hubo, y cuántos movimientos salieron de cada documento.

CREATE OR REPLACE FUNCTION portal_documentos(p_limite int DEFAULT 20)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    RETURN coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', d.id, 'nombre', d.nombre_archivo,
               'formato', coalesce(f.nombre, d.formato_codigo, 'desconocido'),
               'estado', d.estado, 'error', d.error, 'fecha', d.creado_en,
               'movimientos', (SELECT count(*) FROM movimientos m
                               WHERE m.documento_id = d.id))
             ORDER BY d.creado_en DESC, d.id DESC)
      FROM (SELECT * FROM documentos
            WHERE negocio_id = v_negocio
            ORDER BY creado_en DESC, id DESC
            LIMIT greatest(coalesce(p_limite, 20), 1)) d
      LEFT JOIN formatos_documento f ON f.codigo = d.formato_codigo), '[]'::jsonb);
END;
$$;

-- =============================================================================
-- 4. Permisos
-- =============================================================================

GRANT EXECUTE ON FUNCTION
      portal_movimientos_resumen(),
      portal_movimientos(text, int),
      portal_documentos(int)
  TO portal_usuario;
