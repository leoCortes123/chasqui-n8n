CREATE OR REPLACE FUNCTION public.informe_estructura_seca(p_hallazgos jsonb, p_servicio text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_h    jsonb := coalesce(p_hallazgos, '{}'::jsonb);
    v_sec  jsonb := '[]'::jsonb;
    v_hall jsonb := '[]'::jsonb;
    v_pts  jsonb;
BEGIN
    IF jsonb_typeof(v_h -> 'recomendaciones') = 'array'
       AND jsonb_array_length(v_h -> 'recomendaciones') > 0 THEN
        SELECT jsonb_agg(jsonb_build_object(
                 'icono', e ->> 'icono', 'titulo', e ->> 'titulo',
                 'problema', e ->> 'problema', 'impacto', e ->> 'impacto',
                 'opciones', coalesce(e -> 'opciones', '[]'::jsonb),
                 'prioridad', e ->> 'prioridad'))
          INTO v_hall
        FROM (SELECT e FROM jsonb_array_elements(v_h -> 'recomendaciones') e LIMIT 5) s;

        RETURN jsonb_build_object(
            'titular', plantilla_cuerpo_srv('informe.titular_seco', p_servicio,
                         'Esto es lo que encontré en tus números'),
            'hallazgos', coalesce(v_hall, '[]'::jsonb),
            'secciones', '[]'::jsonb,
            'acciones',  '[]'::jsonb,
            'narrado',   false);
    END IF;

    -- Las cifras se copian tal cual del JSON de hallazgos, sin reformatear: son
    -- exactamente las que validar_cifras daría por buenas.
    IF jsonb_typeof(v_h -> 'hechos') = 'array'
       AND jsonb_array_length(v_h -> 'hechos') > 0 THEN
        SELECT jsonb_agg(btrim(coalesce(nullif(e ->> 'contenido', ''), e ->> 'titulo')))
          INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(v_h -> 'hechos') e LIMIT 3) s;

        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '🔎', 'titulo', 'Lo que tengo cargado', 'puntos', v_pts));
        END IF;
    ELSE
        SELECT jsonb_agg(format('%s: deja %s%% de margen',
                                e ->> 'producto', e ->> 'margen_pct')) INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(coalesce(v_h->'margen_bajo','[]'::jsonb)) e
              LIMIT 3) s;
        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '⚠️', 'titulo', 'Margen bajo', 'puntos', v_pts));
        END IF;

        SELECT jsonb_agg(format('%s: el costo se movió %s%%',
                                e ->> 'producto', e ->> 'deriva_pct')) INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(coalesce(v_h->'deriva_costo','[]'::jsonb)) e
              LIMIT 3) s;
        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '📈', 'titulo', 'Les subió el costo', 'puntos', v_pts));
        END IF;

        SELECT jsonb_agg(format('%s: alcanza para %s días',
                                e ->> 'producto', e ->> 'dias_cobertura')) INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(coalesce(v_h->'baja_cobertura','[]'::jsonb)) e
              LIMIT 3) s;
        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '🕐', 'titulo', 'Se agotan pronto', 'puntos', v_pts));
        END IF;

        SELECT jsonb_agg(format('%s: aporta %s%% de la utilidad',
                                e ->> 'producto', e ->> 'pct_utilidad')) INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(coalesce(v_h->'pareto','[]'::jsonb)) e
              LIMIT 3) s;
        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '🏆', 'titulo', 'Concentran la ganancia', 'puntos', v_pts));
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'titular', plantilla_cuerpo_srv('informe.titular_seco', p_servicio,
                     'Esto es lo que encontré en tus números'),
        'secciones', v_sec,
        'acciones', '[]'::jsonb,
        'narrado', false);
END;
$function$
