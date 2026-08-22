-- 072_informe_declara_base.sql — el informe dice de qué datos habla.
--
-- EL PROBLEMA, MEDIDO EN LA SEGUNDA PRUEBA DE USUARIO
--
-- El usuario mandó 101 archivos, entraron 63, y de esos el plan free dejó ver
-- 196 de 380 movimientos. El informe que recibió hablaba de $91.506.262 en
-- compras. En la carpeta había $612.072.404 entre compras y ventas.
--
-- El informe no dijo nada de eso. Su encabezado entero era:
--
--     📊 Análisis de ventas y compras
--     del 2 de junio al 31 de julio de 2026
--     📦 Productos analizados: 64
--
-- El rango es correcto y el conteo también. Pero con esa cabecera no hay forma
-- de que el usuario detecte que le faltó el 99% de sus datos: no dice cuántos
-- archivos usó, no dice que hay movimientos guardados fuera de la ventana del
-- plan, y sobre todo no dice que no tiene UNA SOLA VENTA. El semáforo, encima,
-- daba 99/100 —porque promedia solo las dimensiones que pudo calcular— así que
-- todo lo visible apuntaba a que estaba bien.
--
-- Un informe que no declara su base no se puede auditar, y uno que no se puede
-- auditar no se puede creer. Esta migración agrega ese bloque.
--
-- POR QUÉ SE CALCULA AL RENDERIZAR Y NO EN hallazgos_generar
--
-- Los hallazgos son la entrada del prompt: todo lo que entra ahí el modelo lo
-- puede citar, y la lista de cifras permitidas de `validar_cifras` crece con
-- cada número que se agregue. El conteo de archivos no le sirve al modelo para
-- redactar y sí le daría material para inventar frases sobre la carga. El
-- bloque es de la base, sale de la base y el modelo no lo ve nunca —mismo
-- criterio que el encabezado y el semáforo (025, 047)—.
--
-- El precio es que se calcula unos segundos después que los hallazgos. Con la
-- 071 esa ventana ya no puede traer archivos nuevos (el análisis no arranca
-- hasta que haya silencio), así que la diferencia es teórica.

-- =============================================================================
-- 1. El bloque
-- =============================================================================
-- Cuatro cosas, y ninguna es opcional:
--
--   * De cuántos archivos salió. Es lo único que el usuario puede comparar
--     contra lo que mandó, que es toda la certificación que necesita.
--   * Cuántos movimientos, y de esos cuántos quedaron fuera por el plan.
--   * Ventas y compras por separado. Cero ventas tiene que gritarlo: la mitad
--     de las reglas no puede correr sin ellas y el usuario no tiene por qué
--     saberlo.
--   * El aviso del NIT, que hasta ahora solo aparecía en el resumen de carga y
--     se perdía entre 63 mensajes.
--
-- `negocio_id` sale de los hallazgos (está ahí desde la 025), así que la función
-- no necesita más parámetros que los que informe_render ya tiene a mano.
CREATE OR REPLACE FUNCTION informe_base_bloque(p_hallazgos jsonb,
                                               p_servicio text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_neg      bigint := (p_hallazgos ->> 'negocio_id')::bigint;
    v_lineas   text[] := '{}';
    v_archivos bigint;
    v_vis      bigint;
    v_total    bigint;
    v_ocultos  bigint;
    v_ventas   bigint;
    v_compras  bigint;
    v_desde    date;
    v_hasta    date;
    v_sin_nit  boolean;
BEGIN
    IF v_neg IS NULL THEN RETURN NULL; END IF;

    SELECT count(DISTINCT m.documento_id) FILTER (WHERE m.documento_id IS NOT NULL),
           count(*)
      INTO v_archivos, v_total
    FROM movimientos m WHERE m.negocio_id = v_neg;

    IF v_total = 0 THEN RETURN NULL; END IF;

    SELECT count(*),
           count(*) FILTER (WHERE tipo = 'venta'),
           count(*) FILTER (WHERE tipo = 'compra'),
           min(fecha), max(fecha)
      INTO v_vis, v_ventas, v_compras, v_desde, v_hasta
    FROM mov_visibles WHERE negocio_id = v_neg;

    v_ocultos := v_total - v_vis;

    v_lineas := v_lineas || format('📄 Salió de <b>%s</b> %s tuyos: <b>%s</b> %s.',
        miles(v_archivos), CASE WHEN v_archivos = 1 THEN 'archivo' ELSE 'archivos' END,
        miles(v_vis), CASE WHEN v_vis = 1 THEN 'registro' ELSE 'registros' END);

    -- Ventas y compras por separado. El caso de cero se dice con todas las
    -- letras porque es el que invalida medio informe.
    IF v_ventas = 0 THEN
        v_lineas := v_lineas ||
          '⚠️ <b>No tengo ninguna venta tuya.</b> Sin ventas no puedo calcular '
          'margen, rotación ni qué te deja plata: esto es solo lo que se ve '
          'desde tus compras.'::text;
    ELSIF v_compras = 0 THEN
        v_lineas := v_lineas ||
          '⚠️ <b>No tengo ninguna compra tuya.</b> Sin compras no puedo calcular '
          'margen ni costos: esto es solo lo que se ve desde tus ventas.'::text;
    ELSE
        v_lineas := v_lineas || format('🧾 %s de venta · %s de compra.',
            miles(v_ventas), miles(v_compras));
    END IF;

    -- Lo que está guardado y el plan no deja mirar. Decirlo es la diferencia
    -- entre "no tengo tus datos" y "tengo tus datos y te muestro esta parte".
    IF v_ocultos > 0 THEN
        v_lineas := v_lineas || format(
          '🔒 Tengo <b>%s</b> registros más guardados, fuera de la ventana de tu '
          'plan. No los perdés: mirá /plan.', miles(v_ocultos));
    END IF;

    SELECT (nullif(btrim(coalesce(n.nit, '')), '') IS NULL
            AND EXISTS (SELECT 1 FROM facturas f WHERE f.negocio_id = n.id))
      INTO v_sin_nit
    FROM negocios n WHERE n.id = v_neg;

    IF coalesce(v_sin_nit, false) THEN
        v_lineas := v_lineas ||
          '💡 Tus facturas las tomé todas como compras porque no tengo el NIT de '
          'tu negocio. Cargalo en /portal y voy a saber cuáles son ventas tuyas.'::text;
    END IF;

    RETURN replace(
             plantilla_cuerpo_srv('informe.base', p_servicio,
               E'🧮 <b>Sobre qué calculé esto</b>\n{{lineas}}'),
             '{{lineas}}', array_to_string(v_lineas, E'\n'));
END;
$fn$;

COMMENT ON FUNCTION informe_base_bloque(jsonb, text) IS
  'El bloque que declara de qué datos habla el informe: archivos, registros, '
  'ventas vs compras, lo que el plan esconde y el aviso de NIT. Sale de la '
  'base; el modelo no lo ve. Ver 072_informe_declara_base.sql.';

INSERT INTO plantillas (clave, cuerpo, formato, variables, crudas, teclado) VALUES
('informe.base',
 '🧮 <b>Sobre qué calculé esto</b>
{{lineas}}',
 'html', '["lineas"]'::jsonb, '["lineas"]'::jsonb, '[]'::jsonb)
ON CONFLICT (clave) DO UPDATE
  SET cuerpo = EXCLUDED.cuerpo, formato = EXCLUDED.formato,
      variables = EXCLUDED.variables, crudas = EXCLUDED.crudas,
      activo = true, version = plantillas.version + 1;

-- =============================================================================
-- 2. informe_render llama al bloque
-- =============================================================================
-- Copia exacta de la definición viva con SEIS líneas agregadas (la llamada a
-- informe_base_bloque, justo después del semáforo). No se reescribió a mano: se
-- extrajo de pg_proc y se le insertó el bloque, para que ningún cambio anterior
-- se pierda por una transcripción.
CREATE OR REPLACE FUNCTION informe_render(p_estructura jsonb, p_hallazgos jsonb,
                                          p_servicio text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql STABLE AS $render$

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
$render$;

NOTIFY pgrst, 'reload schema';
