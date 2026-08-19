CREATE OR REPLACE FUNCTION public.portal_recomendaciones(p_limite integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    RETURN jsonb_build_object(
      'vigentes', recomendaciones_vigentes(v_negocio, p_limite),
      -- Las cerradas son la mitad interesante: "esto te lo dije y se arregló".
      'cerradas', coalesce((
         SELECT jsonb_agg(jsonb_build_object(
                  'id', id, 'titulo', titulo, 'impacto', impacto,
                  'icono', icono,
                  'estado', estado, 'cerrada_por', cerrada_por,
                  'resultado', resultado,
                  'cambio_pct', datos ->> 'cambio_pct',
                  'detectada_en', detectada_en, 'cerrada_en', cerrada_en)
                  ORDER BY cerrada_en DESC)
         FROM (SELECT * FROM recomendaciones
                WHERE negocio_id = v_negocio AND estado NOT IN ('nueva','vigente')
                ORDER BY cerrada_en DESC LIMIT p_limite) c), '[]'::jsonb));
END;
$function$
