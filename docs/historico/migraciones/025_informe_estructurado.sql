-- 025_informe_estructurado.sql — el informe se ve como una ficha, no como un
-- muro de texto.
--
-- Hasta ahora el modelo escribía prosa libre y se entregaba tal cual: el
-- resultado dependía del humor del modelo y no había forma de darle una forma
-- estable. Ahora el modelo devuelve JSON con la ESTRUCTURA (titular, secciones,
-- puntos, acciones) y el layout lo pone Postgres con informe_render, leyendo los
-- pedazos de la tabla plantillas. Cambiar cómo se ve el informe vuelve a ser un
-- UPDATE.
--
-- La cabecera de métricas NO la escribe el modelo: sale de los hallazgos, así
-- que sus cifras son las de la base por construcción.
--
-- Además arregla un falso positivo latente de validar_cifras: el prompt pide
-- español de Colombia, donde el decimal va con coma, pero la validación
-- comparaba "28,4" contra el "28.40" de los hallazgos y lo marcaba como cifra
-- inventada. Cada vez que el modelo escribía un porcentaje con coma se quemaba
-- un reintento y se terminaba entregando el informe seco.

-- === 1. Cifras: una forma canónica para comparar =============================
CREATE FUNCTION cifra_canonica(p_num text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN n LIKE '%.%'
                -- solo con parte decimal: los ceros de un entero son cifra
                THEN regexp_replace(regexp_replace(n, '0+$', ''), '\.$', '')
                ELSE n END
    FROM (SELECT replace(
                   regexp_replace(
                     rtrim(coalesce(p_num, ''), '.,'),   -- puntuación de la frase
                     '[.,](?=\d{3}\b)', '', 'g'),        -- separador de miles
                   ',', '.') AS n) s;                    -- coma decimal -> punto
$$;

CREATE OR REPLACE FUNCTION validar_cifras(p_texto text, p_hallazgos jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_permitidos text[];
    v_num        text;
    v_inventadas text[] := '{}';
BEGIN
    SELECT array_agg(DISTINCT cifra_canonica(n)) INTO v_permitidos
    FROM (SELECT (regexp_matches(p_hallazgos::text, '\d+(?:\.\d+)?', 'g'))[1] AS n) s;

    FOR v_num IN
        SELECT cifra_canonica(m[1])
        FROM regexp_matches(coalesce(p_texto, ''), '\d[\d.,]*', 'g') AS m
    LOOP
        IF length(regexp_replace(v_num, '\D', '', 'g')) >= 3
           AND NOT (v_num = ANY(v_permitidos)) THEN
            v_inventadas := array_append(v_inventadas, v_num);
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'ok', cardinality(v_inventadas) = 0,
        'inventadas', to_jsonb(v_inventadas));
END;
$$;

-- === 2. Formateo para el chat ===============================================
-- Decimal con coma, como se lee en Colombia, y sin ceros de relleno:
-- 28.40 -> "28,4", 30.00 -> "30". Se formatea a partir del valor que está en los
-- hallazgos, y cifra_canonica se encarga de que la coma no lo vuelva sospechoso.
CREATE FUNCTION fmt_decimal(p_num numeric) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_num IS NULL THEN ''
      ELSE replace(regexp_replace(regexp_replace(p_num::text, '0+$', ''), '\.$', ''),
                   '.', ',') END;
$$;

CREATE FUNCTION mes_es(p_fecha date) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT (ARRAY['enero','febrero','marzo','abril','mayo','junio','julio',
                  'agosto','septiembre','octubre','noviembre','diciembre']
           )[extract(month from p_fecha)::int];
$$;

-- "del 1 al 24 de julio de 2026" / "del 28 de junio al 3 de julio de 2026"
CREATE FUNCTION periodo_es(p_desde date, p_hasta date) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
      WHEN p_desde IS NULL OR p_hasta IS NULL THEN ''
      WHEN p_desde = p_hasta THEN
        format('%s de %s de %s', extract(day from p_desde)::int,
               mes_es(p_desde), extract(year from p_desde)::int)
      WHEN date_trunc('month', p_desde) = date_trunc('month', p_hasta) THEN
        format('del %s al %s de %s de %s', extract(day from p_desde)::int,
               extract(day from p_hasta)::int, mes_es(p_hasta),
               extract(year from p_hasta)::int)
      WHEN extract(year from p_desde) = extract(year from p_hasta) THEN
        format('del %s de %s al %s de %s de %s',
               extract(day from p_desde)::int, mes_es(p_desde),
               extract(day from p_hasta)::int, mes_es(p_hasta),
               extract(year from p_hasta)::int)
      ELSE
        format('del %s de %s de %s al %s de %s de %s',
               extract(day from p_desde)::int, mes_es(p_desde), extract(year from p_desde)::int,
               extract(day from p_hasta)::int, mes_es(p_hasta), extract(year from p_hasta)::int)
    END;
$$;

-- === 3. hallazgos_generar: se agrega el periodo cubierto =====================
-- El informe necesita decir DE CUÁNDO habla. Al entrar en los hallazgos, sus
-- dígitos quedan además dentro del conjunto que validar_cifras acepta.
CREATE OR REPLACE FUNCTION hallazgos_generar(p_negocio_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_margen_min  numeric := (parametro(p_negocio_id, 'margen_minimo_pct'))::text::numeric;
    v_deriva_ali  numeric := (parametro(p_negocio_id, 'deriva_costo_alerta_pct'))::text::numeric;
    v_dias_cob    numeric := (parametro(p_negocio_id, 'dias_cobertura_min'))::text::numeric;
    v_out jsonb;
BEGIN
    SELECT jsonb_build_object(
      'negocio_id', p_negocio_id,
      'generado_en', now(),
      'umbrales', jsonb_build_object('margen_minimo_pct', v_margen_min,
                                     'deriva_costo_alerta_pct', v_deriva_ali,
                                     'dias_cobertura_min', v_dias_cob),

      'periodo', (SELECT jsonb_build_object(
                    'desde', min(fecha), 'hasta', max(fecha),
                    'movimientos_venta',  count(*) FILTER (WHERE tipo = 'venta'),
                    'movimientos_compra', count(*) FILTER (WHERE tipo = 'compra'))
                  FROM movimientos
                  WHERE negocio_id = p_negocio_id AND fecha IS NOT NULL),

      'resumen', (SELECT jsonb_build_object(
                    'productos', count(*),
                    'con_precio', count(*) FILTER (WHERE precio_actual IS NOT NULL),
                    'margen_promedio_pct', round(avg(margen_pct), 2))
                  FROM v_margen_producto WHERE negocio_id = p_negocio_id),

      'margen_bajo', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'producto', nombre_canonico, 'costo', costo_actual,
                        'precio', precio_actual, 'margen_pct', margen_pct)
                        ORDER BY margen_pct), '[]')
                      FROM v_margen_producto
                      WHERE negocio_id = p_negocio_id
                        AND precio_actual IS NOT NULL
                        AND margen_pct < v_margen_min),

      'deriva_costo', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'producto_id', d.producto_id, 'producto', p.nombre_canonico,
                        'costo_ini', d.costo_ini, 'costo_fin', d.costo_fin,
                        'deriva_pct', d.deriva_pct) ORDER BY abs(d.deriva_pct) DESC), '[]')
                      FROM v_deriva_costo d JOIN productos p ON p.id = d.producto_id
                      WHERE d.negocio_id = p_negocio_id
                        AND abs(d.deriva_pct) >= v_deriva_ali),

      'baja_cobertura', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'producto_id', r.producto_id, 'producto', p.nombre_canonico,
                        'dias_cobertura', r.dias_cobertura,
                        'unidades_por_dia', r.unidades_por_dia) ORDER BY r.dias_cobertura), '[]')
                      FROM v_rotacion_producto r JOIN productos p ON p.id = r.producto_id
                      WHERE r.negocio_id = p_negocio_id
                        AND r.dias_cobertura IS NOT NULL
                        AND r.dias_cobertura < v_dias_cob),

      'pareto', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'producto', p.nombre_canonico, 'utilidad', pa.utilidad,
                        'pct_utilidad', pa.pct_utilidad, 'pct_acumulado', pa.pct_acumulado)
                        ORDER BY pa.utilidad DESC), '[]')
                      FROM v_pareto_utilidad pa JOIN productos p ON p.id = pa.producto_id
                      WHERE pa.negocio_id = p_negocio_id AND pa.pct_acumulado <= 80)
    ) INTO v_out;

    RETURN v_out;
END;
$$;

-- === 4. Piezas del layout, como filas =======================================
INSERT INTO plantillas (clave, cuerpo, formato, variables, crudas) VALUES

('informe.encabezado',
 '📊 <b>{{servicio}}</b>
<i>{{periodo}}</i>

{{metricas}}',
 'html', '["servicio","periodo","metricas"]'::jsonb, '["metricas"]'::jsonb),

('informe.metrica',   '{{icono}} {{etiqueta}}: <b>{{valor}}</b>',
 'html', '["icono","etiqueta","valor"]'::jsonb, '[]'::jsonb),

('informe.titular',   '<b>{{titular}}</b>',
 'html', '["titular"]'::jsonb, '[]'::jsonb),

('informe.seccion',   '{{icono}} <b>{{titulo}}</b>
{{puntos}}',
 'html', '["icono","titulo","puntos"]'::jsonb, '["puntos"]'::jsonb),

('informe.punto',     '• {{texto}}',
 'html', '["texto"]'::jsonb, '[]'::jsonb),

('informe.acciones',  '✅ <b>Qué hacer esta semana</b>
{{puntos}}',
 'html', '["puntos"]'::jsonb, '["puntos"]'::jsonb),

('informe.accion',    '{{n}}. {{texto}}',
 'html', '["n","texto"]'::jsonb, '[]'::jsonb),

('informe.pie',       '<i>Las cifras salen de los archivos que me mandaste. Si alguna no te cuadra, decime y la reviso.</i>',
 'html', '[]'::jsonb, '[]'::jsonb),

('informe.sin_narracion',
 '<i>Nota: no pude verificar el texto del análisis, así que va la lista seca de lo que encontré.</i>',
 'html', '[]'::jsonb, '[]'::jsonb)

ON CONFLICT (clave) DO UPDATE
  SET cuerpo = EXCLUDED.cuerpo, formato = EXCLUDED.formato,
      variables = EXCLUDED.variables, crudas = EXCLUDED.crudas,
      activo = true, version = plantillas.version + 1;

-- === 5. informe_render ======================================================
-- Compone las piezas. Regla de confianza: lo que escribió el MODELO pasa por
-- esc_html; los bloques ya renderizados por nosotros se insertan crudos (por eso
-- la sustitución no se hace con resolver_plantilla, que escaparía dos veces y
-- convertiría un &amp; en &amp;amp;).
--
-- Devuelve NULL si la estructura no sirve. wf_ejecutar trata ese NULL igual que
-- una cifra inventada: reintenta y, si vuelve a fallar, cae al informe seco.

CREATE FUNCTION plantilla_cuerpo(p_clave text, p_defecto text)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT coalesce((SELECT cuerpo FROM plantillas
                     WHERE clave = p_clave AND activo LIMIT 1), p_defecto);
$$;

-- Limpieza mínima del Markdown que se le escape al modelo dentro de un string.
-- Solo ** y __, que nunca son parte de un nombre de producto; un asterisco o
-- guion bajo suelto se deja quieto para no mutilar "ACEITE_1L".
CREATE FUNCTION limpiar_marcado(p_texto text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT btrim(regexp_replace(
             regexp_replace(coalesce(p_texto, ''), '\*\*|__', '', 'g'),
             '^\s*#{1,6}\s*', '', 'g'));
$$;

CREATE FUNCTION informe_render(p_estructura jsonb, p_hallazgos jsonb,
                               p_servicio text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_iconos_ok text[] := ARRAY['⚠️','📈','📉','📦','💰','🏆','🔎','🧾','🕐','✅'];
    v_bloques   text[] := '{}';
    v_metricas  text[] := '{}';
    v_puntos    text[];
    v_sec       jsonb;
    v_pt        text;
    v_icono     text;
    v_titular   text;
    v_nombre    text;
    v_margen    text;
    v_prod      int;
    v_n         int;
    v_tmp       text;
BEGIN
    IF p_estructura IS NULL OR jsonb_typeof(p_estructura) <> 'object' THEN
        RETURN NULL;
    END IF;
    v_titular := limpiar_marcado(p_estructura ->> 'titular');
    IF coalesce(v_titular, '') = '' THEN
        RETURN NULL;
    END IF;

    -- --- Cabecera: cifras de la base, no del modelo -------------------------
    v_nombre := coalesce((SELECT nombre FROM servicios WHERE codigo = p_servicio),
                         'Análisis de tu negocio');
    v_prod   := coalesce((p_hallazgos #>> '{resumen,productos}')::int, 0);
    v_margen := fmt_decimal((p_hallazgos #>> '{resumen,margen_promedio_pct}')::numeric);

    v_tmp := plantilla_cuerpo('informe.metrica', '{{icono}} {{etiqueta}}: <b>{{valor}}</b>');
    IF v_prod > 0 THEN
        v_metricas := v_metricas || replace(replace(replace(v_tmp,
            '{{icono}}', '📦'), '{{etiqueta}}', 'Productos analizados'),
            '{{valor}}', v_prod::text);
    END IF;
    IF v_margen <> '' THEN
        v_metricas := v_metricas || replace(replace(replace(v_tmp,
            '{{icono}}', '💰'), '{{etiqueta}}', 'Margen promedio'),
            '{{valor}}', v_margen || ' %');
    END IF;

    FOR v_icono, v_pt, v_n IN
        SELECT * FROM (VALUES
            ('⚠️', 'Con margen bajo',   jsonb_array_length(coalesce(p_hallazgos->'margen_bajo','[]'::jsonb))),
            ('📈', 'Con costo al alza', jsonb_array_length(coalesce(p_hallazgos->'deriva_costo','[]'::jsonb))),
            ('🕐', 'Se agotan pronto',  jsonb_array_length(coalesce(p_hallazgos->'baja_cobertura','[]'::jsonb))),
            ('🏆', 'Concentran la ganancia', jsonb_array_length(coalesce(p_hallazgos->'pareto','[]'::jsonb)))
        ) AS t(ico, eti, n) WHERE t.n > 0
    LOOP
        v_metricas := v_metricas || replace(replace(replace(v_tmp,
            '{{icono}}', v_icono), '{{etiqueta}}', v_pt), '{{valor}}', v_n::text);
    END LOOP;

    v_bloques := v_bloques || replace(replace(replace(
        plantilla_cuerpo('informe.encabezado',
            E'📊 <b>{{servicio}}</b>\n<i>{{periodo}}</i>\n\n{{metricas}}'),
        '{{servicio}}', esc_html(v_nombre)),
        '{{periodo}}',  esc_html(coalesce(nullif(
            periodo_es((p_hallazgos #>> '{periodo,desde}')::date,
                       (p_hallazgos #>> '{periodo,hasta}')::date), ''),
            'con los archivos que me mandaste'))),
        '{{metricas}}', array_to_string(v_metricas, E'\n'));

    -- --- Titular ------------------------------------------------------------
    v_bloques := v_bloques || replace(
        plantilla_cuerpo('informe.titular', '<b>{{titular}}</b>'),
        '{{titular}}', esc_html(v_titular));

    -- --- Secciones ----------------------------------------------------------
    IF jsonb_typeof(p_estructura -> 'secciones') = 'array' THEN
        FOR v_sec IN SELECT * FROM jsonb_array_elements(p_estructura -> 'secciones') LOOP
            CONTINUE WHEN jsonb_typeof(v_sec) <> 'object';
            CONTINUE WHEN coalesce(v_sec ->> 'titulo', '') = '';

            v_puntos := '{}';
            IF jsonb_typeof(v_sec -> 'puntos') = 'array' THEN
                FOR v_pt IN SELECT * FROM jsonb_array_elements_text(v_sec -> 'puntos') LOOP
                    CONTINUE WHEN coalesce(btrim(v_pt), '') = '';
                    v_puntos := v_puntos || replace(
                        plantilla_cuerpo('informe.punto', '• {{texto}}'),
                        '{{texto}}', esc_html(limpiar_marcado(v_pt)));
                END LOOP;
            END IF;
            CONTINUE WHEN cardinality(v_puntos) = 0;

            -- El icono viene del modelo: solo se aceptan los de la lista.
            v_icono := v_sec ->> 'icono';
            IF v_icono IS NULL OR NOT (v_icono = ANY(v_iconos_ok)) THEN
                v_icono := '🔎';
            END IF;

            v_bloques := v_bloques || replace(replace(replace(
                plantilla_cuerpo('informe.seccion', E'{{icono}} <b>{{titulo}}</b>\n{{puntos}}'),
                '{{icono}}',  v_icono),
                '{{titulo}}', esc_html(limpiar_marcado(v_sec ->> 'titulo'))),
                '{{puntos}}', array_to_string(v_puntos, E'\n'));
        END LOOP;
    END IF;

    -- --- Acciones -----------------------------------------------------------
    IF jsonb_typeof(p_estructura -> 'acciones') = 'array' THEN
        v_puntos := '{}';
        v_n := 0;
        FOR v_pt IN SELECT * FROM jsonb_array_elements_text(p_estructura -> 'acciones') LOOP
            CONTINUE WHEN coalesce(btrim(v_pt), '') = '';
            v_n := v_n + 1;
            v_puntos := v_puntos || replace(replace(
                plantilla_cuerpo('informe.accion', '{{n}}. {{texto}}'),
                '{{n}}', v_n::text),
                '{{texto}}', esc_html(limpiar_marcado(v_pt)));
        END LOOP;
        IF cardinality(v_puntos) > 0 THEN
            v_bloques := v_bloques || replace(
                plantilla_cuerpo('informe.acciones', E'✅ <b>Qué hacer esta semana</b>\n{{puntos}}'),
                '{{puntos}}', array_to_string(v_puntos, E'\n'));
        END IF;
    END IF;

    -- --- Pie ----------------------------------------------------------------
    IF coalesce((p_estructura ->> 'narrado')::boolean, true) = false THEN
        v_bloques := v_bloques || plantilla_cuerpo('informe.sin_narracion', '');
    END IF;
    v_bloques := v_bloques || plantilla_cuerpo('informe.pie', '');

    -- Doble salto entre bloques: es lo que usa wf_ejecutar para partir el
    -- informe en varios mensajes sin cortar una sección por la mitad. El
    -- colapso de saltos cubre los bloques que quedan a medias (una cabecera sin
    -- métricas, por ejemplo) sin tener que ramificar por cada caso.
    RETURN regexp_replace(btrim(array_to_string(
        ARRAY(SELECT b FROM unnest(v_bloques) AS b WHERE btrim(b) <> ''), E'\n\n')),
        E'\n{3,}', E'\n\n', 'g');
END;
$$;

-- === 6. El prompt devuelve estructura, no prosa ==============================
-- Y de paso se corrige el público: no son tiendas de barrio sin registros, son
-- negocios que ya llevan sus números en digital.
UPDATE prompts SET
    sistema =
'Sos el analista de una pyme colombiana que ya lleva sus números en digital. Escribís claro, directo y en español de Colombia, sin tecnicismos y sin rodeos.

REGLA ABSOLUTA: solo podés usar cifras que aparezcan textualmente en los HALLAZGOS que te doy. Está prohibido calcular, sumar, estimar o inventar un número que no esté ahí. Si un dato no está, decilo con palabras. Los valores son pesos colombianos.

Respondés ÚNICAMENTE con un objeto JSON válido, sin texto antes ni después y sin bloques de código. Este es el esquema:

{
  "titular": "una sola frase de máximo 100 caracteres con lo más importante que encontraste",
  "secciones": [
    {
      "icono": "uno de estos exactamente: ⚠️ 📈 🕐 🏆 💰 🔎",
      "titulo": "máximo 40 caracteres",
      "puntos": ["una frase concreta por producto o por hallazgo"]
    }
  ],
  "acciones": ["qué hacer esta semana, en imperativo y concreto"]
}

Reglas del contenido: máximo 4 secciones, máximo 3 puntos por sección y máximo 3 acciones. Incluí solo las secciones que tengan datos reales en los hallazgos; si una lista viene vacía, no inventes la sección. No repitas el titular dentro de los puntos. Nada de Markdown ni asteriscos dentro de los textos: el formato lo pone el sistema. No saludes ni te despidas.',
    usuario =
'Con base EXCLUSIVAMENTE en estos hallazgos, armá el JSON del informe para el dueño del negocio. Cubrí, en este orden y solo si hay datos: productos que dejan poco o ningún margen, productos a los que les subió el costo y hay que revisar el precio, productos que se van a agotar pronto, y los pocos productos que concentran la ganancia.

HALLAZGOS:
{{hallazgos}}',
    version = version + 1
WHERE servicio_codigo = 'ventas_compras' AND activo;

-- === 7. Entrega: el cuerpo ya viene renderizado =============================
-- El encabezado dejó de estar en la plantilla (ahora lo pone informe_render), y
-- {{texto}} se declara CRUDA: es HTML que generamos nosotros, no contenido de
-- terceros. Las dos plantillas comparten el nombre de variable para que
-- wf_ejecutar no tenga que distinguirlas.
UPDATE plantillas SET
    cuerpo    = '{{texto}}',
    variables = '["texto"]'::jsonb,
    crudas    = '["texto"]'::jsonb,
    formato   = 'html',
    teclado   = '[[{"texto":"🔄 Analizar otra vez","dato":"/nueva"}]]'::jsonb,
    version   = version + 1
WHERE clave = 'ejecucion.entregada';

UPDATE plantillas SET
    cuerpo    = '{{texto}}',
    variables = '["texto"]'::jsonb,
    crudas    = '["texto"]'::jsonb,
    formato   = 'html',
    teclado   = '[]'::jsonb,
    version   = version + 1
WHERE clave = 'ejecucion.informe_parte';
