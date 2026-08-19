CREATE OR REPLACE FUNCTION public.portal_documentos(p_limite integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
$function$
