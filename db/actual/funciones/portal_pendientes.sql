CREATE OR REPLACE FUNCTION public.portal_pendientes()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    RETURN coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', f.id, 'pregunta', f.pregunta, 'veces', f.veces,
               'ultima_en', f.ultima_en,
               'candidato_id', f.candidato_id, 'candidato', f.candidato)
             ORDER BY f.veces DESC, f.ultima_en DESC)
      FROM v_conocimiento_faltante f WHERE f.negocio_id = v_negocio), '[]'::jsonb);
END;
$function$
