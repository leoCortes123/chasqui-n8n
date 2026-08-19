CREATE OR REPLACE FUNCTION public.informe_render(p_estructura jsonb, p_hallazgos jsonb, p_servicio text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$

DECLARE
    v_iconos_ok text[] := ARRAY['⚠️','📈','📉','📦','💰','🏆','🔎','🧾','🕐','✅'];
    v_bloques   text[] := '{}';
    v_metricas  text[] := '{}';
    v_partes    text[];
    v_puntos    text[];
    v_enc       jsonb;
    v_sec       jsonb;
    v_pt        text;
    v_icono     text;
    v_titular   text;
    v_nombre    text;
    v_subtitulo text;
    v_margen    text;
    v_prio      text;
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

    v_enc := CASE WHEN jsonb_typeof(p_hallazgos -> 'encabezado') = 'object'
                  THEN p_hallazgos -> 'encabezado' ELSE NULL END;
    v_tmp := plantilla_cuerpo_srv('informe.metrica', p_servicio,
                                  '{{icono}} {{etiqueta}}: <b>{{valor}}</b>');

    IF v_enc IS NOT NULL THEN
        -- --- Cabecera declarada por el servicio ------------------------------
        v_nombre    := coalesce(nullif(v_enc ->> 'titulo', ''),
                        (SELECT nombre FROM servicios WHERE codigo = p_servicio),
                        'Tu negocio');
        v_subtitulo := coalesce(v_enc ->> 'subtitulo', '');

        IF jsonb_typeof(v_enc -> 'metricas') = 'array' THEN
            FOR v_sec IN SELECT * FROM jsonb_array_elements(v_enc -> 'metricas') LOOP
                CONTINUE WHEN jsonb_typeof(v_sec) <> 'object';
                CONTINUE WHEN coalesce(v_sec ->> 'etiqueta', '') = '';
                v_icono := v_sec ->> 'icono';
                IF v_icono IS NULL OR NOT (v_icono = ANY(v_iconos_ok)) THEN
                    v_icono := '🔎';
                END IF;
                v_metricas := v_metricas || replace(replace(replace(v_tmp,
                    '{{icono}}', v_icono),
                    '{{etiqueta}}', esc_html(v_sec ->> 'etiqueta')),
                    '{{valor}}', esc_html(coalesce(v_sec ->> 'valor', '')));
            END LOOP;
        END IF;
    ELSE
        -- --- Cabecera de ventas-compras: cifras de la base, no del modelo ----
        v_nombre := coalesce((SELECT nombre FROM servicios WHERE codigo = p_servicio),
                             'Análisis de tu negocio');
        v_prod   := coalesce((p_hallazgos #>> '{resumen,productos}')::int, 0);
        v_margen := fmt_decimal((p_hallazgos #>> '{resumen,margen_promedio_pct}')::numeric);

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

        v_subtitulo := coalesce(nullif(
            periodo_es((p_hallazgos #>> '{periodo,desde}')::date,
                       (p_hallazgos #>> '{periodo,hasta}')::date), ''),
            'con los archivos que me mandaste');
    END IF;

    v_bloques := v_bloques || replace(replace(replace(
        plantilla_cuerpo_srv('informe.encabezado', p_servicio,
            E'📊 <b>{{servicio}}</b>\n<i>{{periodo}}</i>\n\n{{metricas}}'),
        '{{servicio}}', esc_html(v_nombre)),
        '{{periodo}}',  esc_html(v_subtitulo)),
        '{{metricas}}', array_to_string(v_metricas, E'\n'));

    -- --- Salud del negocio (de la base, no del modelo) ----------------------
    v_tmp := informe_salud_bloque(p_hallazgos -> 'salud', p_servicio);
    IF v_tmp IS NOT NULL THEN
        v_bloques := v_bloques || v_tmp;
    END IF;

    -- --- De qué datos habla este informe (072) ------------------------------
    -- Va DESPUÉS de la salud y ANTES del titular a propósito: el usuario tiene
    -- que saber sobre qué se calculó el semáforo antes de leer una conclusión.
    v_tmp := informe_base_bloque(p_hallazgos, p_servicio);
    IF v_tmp IS NOT NULL THEN
        v_bloques := v_bloques || v_tmp;
    END IF;

    -- --- Titular ------------------------------------------------------------
    v_bloques := v_bloques || replace(
        plantilla_cuerpo_srv('informe.titular', p_servicio, '<b>{{titular}}</b>'),
        '{{titular}}', esc_html(v_titular));

    -- --- Hallazgos prescriptivos --------------------------------------------
    IF jsonb_typeof(p_estructura -> 'hallazgos') = 'array' THEN
        FOR v_sec IN SELECT * FROM jsonb_array_elements(p_estructura -> 'hallazgos') LOOP
            CONTINUE WHEN jsonb_typeof(v_sec) <> 'object';
            CONTINUE WHEN coalesce(v_sec ->> 'titulo', '') = '';

            v_icono := v_sec ->> 'icono';
            IF v_icono IS NULL OR NOT (v_icono = ANY(v_iconos_ok)) THEN
                v_icono := '🔎';
            END IF;

            v_partes := ARRAY[ replace(replace(
                plantilla_cuerpo_srv('informe.hallazgo_titulo', p_servicio,
                    '{{icono}} <b>{{titulo}}</b>'),
                '{{icono}}',  v_icono),
                '{{titulo}}', esc_html(limpiar_marcado(v_sec ->> 'titulo'))) ];

            IF coalesce(btrim(v_sec ->> 'problema'), '') <> '' THEN
                v_partes := v_partes || replace(
                    plantilla_cuerpo_srv('informe.hallazgo_problema', p_servicio, '{{texto}}'),
                    '{{texto}}', esc_html(limpiar_marcado(v_sec ->> 'problema')));
            END IF;

            IF coalesce(btrim(v_sec ->> 'impacto'), '') <> '' THEN
                v_partes := v_partes || replace(
                    plantilla_cuerpo_srv('informe.hallazgo_impacto', p_servicio,
                        '💸 <b>{{texto}}</b>'),
                    '{{texto}}', esc_html(limpiar_marcado(v_sec ->> 'impacto')));
            END IF;

            IF jsonb_typeof(v_sec -> 'opciones') = 'array' THEN
                FOR v_pt IN SELECT * FROM jsonb_array_elements_text(v_sec -> 'opciones') LOOP
                    CONTINUE WHEN coalesce(btrim(v_pt), '') = '';
                    v_partes := v_partes || replace(
                        plantilla_cuerpo_srv('informe.opcion', p_servicio, '✓ {{texto}}'),
                        '{{texto}}', esc_html(limpiar_marcado(v_pt)));
                END LOOP;
            END IF;

            -- La prioridad del modelo solo se acepta si es una de las tres.
            v_prio := lower(coalesce(v_sec ->> 'prioridad', ''));
            IF v_prio IN ('alta','media','baja') THEN
                v_partes := v_partes || replace(replace(
                    plantilla_cuerpo_srv('informe.hallazgo_prioridad', p_servicio,
                        '{{semaforo}} Prioridad {{nivel}}'),
                    '{{semaforo}}', CASE v_prio WHEN 'alta' THEN '🔴'
                                                WHEN 'media' THEN '🟡' ELSE '🟢' END),
                    '{{nivel}}', v_prio);
            END IF;

            v_bloques := v_bloques || array_to_string(v_partes, E'\n');
        END LOOP;
    END IF;

    -- --- Secciones (forma clásica; la usan los servicios sin motor de reglas) -
    IF jsonb_typeof(p_estructura -> 'secciones') = 'array' THEN
        FOR v_sec IN SELECT * FROM jsonb_array_elements(p_estructura -> 'secciones') LOOP
            CONTINUE WHEN jsonb_typeof(v_sec) <> 'object';
            CONTINUE WHEN coalesce(v_sec ->> 'titulo', '') = '';

            v_puntos := '{}';
            IF jsonb_typeof(v_sec -> 'puntos') = 'array' THEN
                FOR v_pt IN SELECT * FROM jsonb_array_elements_text(v_sec -> 'puntos') LOOP
                    CONTINUE WHEN coalesce(btrim(v_pt), '') = '';
                    v_puntos := v_puntos || replace(
                        plantilla_cuerpo_srv('informe.punto', p_servicio, '• {{texto}}'),
                        '{{texto}}', esc_html(limpiar_marcado(v_pt)));
                END LOOP;
            END IF;
            CONTINUE WHEN cardinality(v_puntos) = 0;

            v_icono := v_sec ->> 'icono';
            IF v_icono IS NULL OR NOT (v_icono = ANY(v_iconos_ok)) THEN
                v_icono := '🔎';
            END IF;

            v_bloques := v_bloques || replace(replace(replace(
                plantilla_cuerpo_srv('informe.seccion', p_servicio,
                    E'{{icono}} <b>{{titulo}}</b>\n{{puntos}}'),
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
                plantilla_cuerpo_srv('informe.accion', p_servicio, '{{n}}. {{texto}}'),
                '{{n}}', v_n::text),
                '{{texto}}', esc_html(limpiar_marcado(v_pt)));
        END LOOP;
        IF cardinality(v_puntos) > 0 THEN
            v_bloques := v_bloques || replace(
                plantilla_cuerpo_srv('informe.acciones', p_servicio,
                    E'✅ <b>Qué hacer esta semana</b>\n{{puntos}}'),
                '{{puntos}}', array_to_string(v_puntos, E'\n'));
        END IF;
    END IF;

    -- --- Pie ----------------------------------------------------------------
    IF coalesce((p_estructura ->> 'narrado')::boolean, true) = false THEN
        v_bloques := v_bloques || plantilla_cuerpo_srv('informe.sin_narracion', p_servicio, '');
    END IF;
    v_bloques := v_bloques || plantilla_cuerpo_srv('informe.pie', p_servicio, '');

    RETURN array_to_string(array_remove(v_bloques, ''), E'\n\n');
END;
$function$
