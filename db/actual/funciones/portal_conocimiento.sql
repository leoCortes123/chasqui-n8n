CREATE OR REPLACE FUNCTION public.portal_conocimiento(p_tipo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    RETURN coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', c.id, 'tipo', c.tipo, 'clave', c.clave, 'titulo', c.titulo,
               'contenido', c.contenido, 'datos', c.datos, 'origen', c.origen,
               'vigente_hasta', c.vigente_hasta,
               'actualizado_en', c.actualizado_en)
             ORDER BY c.tipo, c.titulo)
      FROM conocimiento c
      WHERE c.negocio_id = v_negocio
        AND (p_tipo IS NULL OR c.tipo = p_tipo)), '[]'::jsonb);
END;
$function$
