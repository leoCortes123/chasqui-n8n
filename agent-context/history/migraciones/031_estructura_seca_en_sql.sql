-- 031_estructura_seca_en_sql.sql — el informe seco deja de saber de ventas.
--
-- Cuando el modelo falla dos veces (cifras inventadas, respuesta truncada o
-- JSON irrecuperable), wf_ejecutar arma la estructura a mano desde los
-- hallazgos. Ese armado estaba en un nodo Code, con los nombres de las listas de
-- ventas-compras escritos en JavaScript: margen_bajo, deriva_costo,
-- baja_cobertura, pareto.
--
-- Era el último pedazo de comportamiento de un servicio que vivía en n8n, y se
-- notó apenas hubo un segundo servicio: una consulta a la base de conocimiento
-- que fallara dos veces contestaba "Esto es lo que encontré en tus números"
-- seguido de nada.
--
-- Ahora la estructura de reserva la arma Postgres y despacha por la forma de los
-- hallazgos: si traen `hechos` (los servicios de conocimiento), lista los
-- hechos; si traen las listas del análisis, lista el análisis. Un servicio nuevo
-- que necesite otra cosa agrega una rama acá, no en un workflow.

INSERT INTO plantillas (clave, cuerpo, formato, variables, teclado) VALUES
('informe.titular_seco',
 'Esto es lo que encontré en tus números',
 'html', '[]'::jsonb, '[]'::jsonb),
('informe.titular_seco.consulta',
 'Esto es lo que tengo cargado sobre eso',
 'html', '[]'::jsonb, '[]'::jsonb)
ON CONFLICT (clave) DO UPDATE
  SET cuerpo = EXCLUDED.cuerpo, formato = EXCLUDED.formato,
      activo = true, version = plantillas.version + 1;

-- El pie de la consulta habla de verificación; en el camino seco la nota de
-- "no pude verificar" ya la pone informe_render, así que no se duplica.

CREATE OR REPLACE FUNCTION informe_estructura_seca(p_hallazgos jsonb,
                                                   p_servicio  text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_h    jsonb := coalesce(p_hallazgos, '{}'::jsonb);
    v_sec  jsonb := '[]'::jsonb;
    v_pts  jsonb;   -- hasta 3 puntos por sección, como hacía el nodo Code
BEGIN
    -- Las cifras se copian tal cual del JSON de hallazgos, sin reformatear: son
    -- exactamente las que validar_cifras daría por buenas.
    -- --- Servicios de conocimiento (consulta, y mañana el cotizador) --------
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
        -- --- Análisis de ventas y compras -----------------------------------
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
$$;
