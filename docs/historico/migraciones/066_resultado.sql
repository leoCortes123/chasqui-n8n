-- 066_resultado.sql — se cierra la pregunta que ninguna de las fases anteriores
-- podía hacer: ¿sirvió?
--
-- B2 dejó los dos ejes separados desde el diseño: `estado` responde "¿qué pasó
-- con la recomendación?" y `resultado` responde "¿sirvió?". La columna
-- `resultado` existe desde entonces, con su CHECK, en NULL, y B2 y D1 no la
-- escriben nunca. Esta migración es la que la llena.
--
-- LOS DOS EJES NO SON EL MISMO, Y ACÁ SE VE POR QUÉ
--
-- "Aplicar el precio sugerido" puede quedar perfectamente ejecutada por el
-- usuario —`estado = resuelta`, `cerrada_por = accion_usuario`— y aun así
-- producir un resultado negativo: subió el precio y dejó de vender. Colapsar las
-- dos cosas en una columna habría hecho imposible distinguir "me hicieron caso"
-- de "les fue bien", que es justo lo que hay que saber para mejorar las reglas.
--
-- CÓMO SE MIDE, SIN INVENTAR UN MODELO
--
-- Cada regla apunta a una magnitud concreta y a una dirección: el costo debería
-- BAJAR, el margen debería SUBIR, el inventario quieto debería BAJAR. Eso es una
-- tabla de dos columnas, no un algoritmo:
--
--   1. Al cerrarse, la recomendación guarda el valor de SU magnitud (`datos.
--      valor_al_cerrar`). Sin esa foto no hay contra qué comparar después.
--   2. Cuando entran datos nuevos —movimientos posteriores al cierre— se vuelve
--      a leer la magnitud y se compara en la dirección que corresponde.
--   3. Un cambio menor que el umbral es `neutro`. La mayoría de las cosas no
--      cambian, y decir "sirvió" por un 1% sería ruido disfrazado de señal.
--
-- LO QUE NO SE MIDE, Y SE DICE
--
-- Sin movimientos posteriores al cierre no se mide nada: `resultado` queda NULL
-- y se vuelve a intentar en el análisis siguiente. Una recomendación cerrada
-- ayer no tiene resultado hoy, y fingir que sí es peor que esperar.

-- =============================================================================
-- 1. Qué magnitud mira cada regla
-- =============================================================================
-- Una fila por regla. Agregar una regla nueva al motor y poder medirla es un
-- INSERT, igual que `intenciones` (063) y `servicios.funcion_hallazgos`.
CREATE TABLE IF NOT EXISTS metricas_resultado (
    regla     text PRIMARY KEY,
    metrica   text NOT NULL
              CHECK (metrica IN ('costo','margen_pct','dias_cobertura','balance',
                                 'concentracion_pct','unidades_vendidas','ventas')),
    -- Hacia dónde tiene que moverse para que haya servido.
    direccion text NOT NULL CHECK (direccion IN ('sube_mejor','baja_mejor')),
    -- Cambio mínimo, en porcentaje, para dejar de ser `neutro`.
    umbral_pct numeric NOT NULL DEFAULT 5
);

COMMENT ON TABLE metricas_resultado IS
  'Qué magnitud mira cada regla para saber si sirvió, y hacia dónde debería '
  'moverse. Es una tabla y no un algoritmo: medir una regla nueva es un INSERT.';

INSERT INTO metricas_resultado (regla, metrica, direccion, umbral_pct) VALUES
  ('costo',           'costo',             'baja_mejor', 5),
  ('proveedor',       'costo',             'baja_mejor', 5),
  ('proveedor_sube',  'costo',             'baja_mejor', 5),
  ('margen',          'margen_pct',        'sube_mejor', 5),
  ('margen_cae',      'margen_pct',        'sube_mejor', 5),
  -- "Se agota" sirvió si se repuso: el stock tiene que haber subido.
  ('agota',           'balance',           'sube_mejor', 10),
  -- "Plata quieta" sirvió si se movió: el stock tiene que haber bajado.
  ('quieto',          'balance',           'baja_mejor', 10),
  -- "Dejó de venderse" sirvió si volvió a venderse, y ahí basta con que se haya
  -- vendido algo: el umbral es 0 porque cualquier venta es la señal.
  ('sin_ventas',      'unidades_vendidas', 'sube_mejor', 0),
  ('dependencia',     'concentracion_pct', 'baja_mejor', 5),
  ('vs_ano_anterior', 'ventas',            'sube_mejor', 5)
ON CONFLICT (regla) DO UPDATE
  SET metrica = EXCLUDED.metrica, direccion = EXCLUDED.direccion,
      umbral_pct = EXCLUDED.umbral_pct;

-- =============================================================================
-- 2. Leer una magnitud
-- =============================================================================
-- Una función para las siete, con el mismo criterio que el agregador de C2: las
-- magnitudes se diferencian en de dónde salen, no en la forma del resultado.
--
-- `p_desde` solo lo usan las magnitudes de flujo (lo vendido, las ventas): las
-- de estado —costo, margen, stock— son el valor de hoy y no dependen de una
-- ventana.
CREATE OR REPLACE FUNCTION recomendacion_metrica_valor(p_negocio_id bigint,
                                                       p_clave      text,
                                                       p_metrica    text,
                                                       p_desde      date DEFAULT NULL)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_prod bigint := CASE WHEN p_clave LIKE 'producto:%'
                          THEN nullif(split_part(p_clave, ':', 2), '')::bigint END;
    v_prov text   := CASE WHEN p_clave LIKE 'proveedor:%'
                          THEN substring(p_clave FROM 11) END;
    v_val  numeric;
BEGIN
    IF p_metrica = 'costo' THEN
        SELECT costo_actual INTO v_val FROM v_margen_producto
        WHERE negocio_id = p_negocio_id AND producto_id = v_prod;

    ELSIF p_metrica = 'margen_pct' THEN
        SELECT margen_pct INTO v_val FROM v_margen_producto
        WHERE negocio_id = p_negocio_id AND producto_id = v_prod;

    ELSIF p_metrica = 'dias_cobertura' THEN
        SELECT dias_cobertura INTO v_val FROM v_rotacion_producto
        WHERE negocio_id = p_negocio_id AND producto_id = v_prod;

    ELSIF p_metrica = 'balance' THEN
        SELECT balance INTO v_val FROM v_balance_unidades
        WHERE negocio_id = p_negocio_id AND producto_id = v_prod;

    ELSIF p_metrica = 'unidades_vendidas' THEN
        SELECT coalesce(sum(cantidad), 0) INTO v_val FROM mov_visibles
        WHERE negocio_id = p_negocio_id AND tipo = 'venta'
          AND producto_id = v_prod
          AND (p_desde IS NULL OR fecha >= p_desde);

    ELSIF p_metrica = 'ventas' THEN
        SELECT coalesce(sum(valor_total), 0) INTO v_val FROM mov_visibles
        WHERE negocio_id = p_negocio_id AND tipo = 'venta'
          AND (p_desde IS NULL OR fecha >= p_desde);

    ELSIF p_metrica = 'concentracion_pct' THEN
        SELECT max(gasto) * 100.0 / nullif(sum(gasto), 0) INTO v_val
        FROM (SELECT nullif(btrim(coalesce(raw ->> 'proveedor','')),'') AS prov,
                     sum(valor_total) AS gasto
              FROM mov_visibles
              WHERE negocio_id = p_negocio_id AND tipo = 'compra'
                AND nullif(btrim(coalesce(raw ->> 'proveedor','')),'') IS NOT NULL
              GROUP BY 1) g;
    END IF;

    RETURN v_val;
END;
$$;

-- =============================================================================
-- 3. La foto al cerrar
-- =============================================================================
-- Sin esto no hay nada contra qué comparar después. Se guarda dentro de `datos`
-- para no agregar columnas por cada cosa que se quiera recordar.
CREATE OR REPLACE FUNCTION recomendacion_marcar_cierre(p_reco_id bigint)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_r record;
    v_m record;
    v_v numeric;
BEGIN
    SELECT * INTO v_r FROM recomendaciones WHERE id = p_reco_id;
    IF v_r.id IS NULL THEN RETURN; END IF;

    SELECT * INTO v_m FROM metricas_resultado WHERE regla = v_r.regla;
    IF v_m.regla IS NULL THEN RETURN; END IF;   -- regla sin métrica: no se mide

    -- Las magnitudes de flujo se miden DESDE el cierre, así que su valor al
    -- cerrar es cero por definición: lo que se cuenta es lo que pase después.
    IF v_m.metrica IN ('unidades_vendidas','ventas') THEN
        v_v := 0;
    ELSE
        v_v := recomendacion_metrica_valor(v_r.negocio_id, v_r.clave_objeto,
                                           v_m.metrica);
    END IF;

    UPDATE recomendaciones
       SET datos = coalesce(datos, '{}'::jsonb)
                   || jsonb_build_object('valor_al_cerrar', v_v,
                                         'metrica_resultado', v_m.metrica)
     WHERE id = p_reco_id;
END;
$$;

-- =============================================================================
-- 4. La medición
-- =============================================================================
-- Corre después de cada análisis. Solo mide lo que se puede medir: hace falta
-- que hayan entrado movimientos DESPUÉS del cierre, o no hay periodo siguiente
-- contra el cual contrastar.
CREATE OR REPLACE FUNCTION recomendaciones_medir(p_negocio_id bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    r        record;
    v_ahora  numeric;
    v_antes  numeric;
    v_delta  numeric;
    v_res    text;
    v_n      jsonb := jsonb_build_object('positivo', 0, 'neutro', 0,
                                         'negativo', 0, 'sin_datos', 0);
BEGIN
    FOR r IN
        SELECT re.*, m.metrica, m.direccion, m.umbral_pct
        FROM recomendaciones re
        JOIN metricas_resultado m ON m.regla = re.regla
        WHERE re.negocio_id = p_negocio_id
          AND re.estado NOT IN ('nueva','vigente')
          AND re.resultado IS NULL
          AND re.cerrada_en IS NOT NULL
          AND re.datos ? 'valor_al_cerrar'
    LOOP
        -- ¿Llegaron datos después del cierre? Se mira `creado_en` y NO `fecha`:
        -- un archivo con ventas fechadas la semana que viene ya estaba cargado
        -- cuando se cerró la recomendación, así que no dice nada sobre si la
        -- acción sirvió. Lo que importa es que haya entrado información nueva,
        -- no que haya filas con fecha posterior.
        IF NOT EXISTS (SELECT 1 FROM mov_visibles
                        WHERE negocio_id = p_negocio_id
                          AND creado_en > r.cerrada_en) THEN
            v_n := jsonb_set(v_n, '{sin_datos}',
                     to_jsonb((v_n ->> 'sin_datos')::int + 1));
            CONTINUE;
        END IF;

        v_antes := nullif(r.datos ->> 'valor_al_cerrar', '')::numeric;
        v_ahora := recomendacion_metrica_valor(p_negocio_id, r.clave_objeto,
                                               r.metrica, r.cerrada_en::date);

        IF v_ahora IS NULL OR v_antes IS NULL THEN
            v_n := jsonb_set(v_n, '{sin_datos}',
                     to_jsonb((v_n ->> 'sin_datos')::int + 1));
            CONTINUE;
        END IF;

        -- Cambio relativo. Con un valor de partida en cero —el caso de las
        -- magnitudes de flujo— cualquier movimiento es 100%: es lo correcto,
        -- porque ahí la pregunta es "¿pasó algo?" y no "¿cuánto cambió?".
        v_delta := CASE WHEN coalesce(v_antes, 0) = 0
                        THEN CASE WHEN v_ahora = 0 THEN 0 ELSE 100 END
                        ELSE (v_ahora - v_antes) * 100.0 / abs(v_antes) END;

        v_res := CASE
          WHEN abs(v_delta) < r.umbral_pct THEN 'neutro'
          WHEN (r.direccion = 'sube_mejor' AND v_delta > 0)
            OR (r.direccion = 'baja_mejor' AND v_delta < 0) THEN 'positivo'
          ELSE 'negativo' END;

        UPDATE recomendaciones
           SET resultado = v_res,
               datos = coalesce(datos, '{}'::jsonb) || jsonb_build_object(
                         'valor_al_medir', round(v_ahora, 4),
                         'cambio_pct', round(v_delta, 1),
                         'medido_en', current_date)
         WHERE id = r.id;

        v_n := jsonb_set(v_n, ARRAY[v_res], to_jsonb((v_n ->> v_res)::int + 1));
    END LOOP;

    RETURN v_n;
END;
$$;

-- =============================================================================
-- 5. Engancharlo donde ya corre todo lo demás
-- =============================================================================
-- La foto al cerrar, en las dos vías por las que una recomendación se cierra:
-- la acción del usuario (D1) y el cierre automático por dato (B2).
CREATE OR REPLACE FUNCTION recomendacion_accion(p_reco_id    bigint,
                                                p_negocio_id bigint,
                                                p_accion     text,
                                                p_usuario_id bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_r      record;
    v_precio numeric;
BEGIN
    SELECT * INTO v_r FROM recomendaciones
    WHERE id = p_reco_id AND negocio_id = p_negocio_id
      AND estado IN ('nueva','vigente');

    IF v_r.id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_encontrada');
    END IF;

    -- >>> 066: la foto ANTES de cerrar. Después de cerrar da lo mismo, pero
    -- hacerlo antes deja el orden explícito y a prueba de reordenamientos.
    PERFORM recomendacion_marcar_cierre(p_reco_id);

    IF p_accion = 'hice' THEN
        UPDATE recomendaciones
           SET estado = 'resuelta', cerrada_por = 'accion_usuario',
               cerrada_en = now()
         WHERE id = p_reco_id;
        RETURN jsonb_build_object('ok', true, 'accion', 'hice',
                                  'titulo', v_r.titulo);

    ELSIF p_accion = 'no_aplica' THEN
        UPDATE recomendaciones
           SET estado = 'ignorada', cerrada_por = 'accion_usuario',
               cerrada_en = now()
         WHERE id = p_reco_id;
        RETURN jsonb_build_object('ok', true, 'accion', 'no_aplica',
                                  'titulo', v_r.titulo);

    ELSIF p_accion = 'precio' THEN
        v_precio := nullif(v_r.datos ->> 'precio_sugerido', '')::numeric;
        IF v_precio IS NULL OR v_precio <= 0 THEN
            RETURN jsonb_build_object('ok', false, 'error', 'sin_precio');
        END IF;

        PERFORM conocimiento_guardar(
          p_negocio_id, 'precio', v_r.titulo,
          format('Precio sugerido por Chasqui a partir de %s.', v_r.regla),
          v_r.titulo,
          jsonb_build_object('valor', v_precio, 'origen', 'recomendacion',
                             'recomendacion_id', p_reco_id),
          'chat', p_usuario_id);

        UPDATE recomendaciones
           SET estado = 'resuelta', cerrada_por = 'accion_usuario',
               cerrada_en = now()
         WHERE id = p_reco_id;

        RETURN jsonb_build_object('ok', true, 'accion', 'precio',
                                  'titulo', v_r.titulo,
                                  'precio', '$' || miles(v_precio));
    END IF;

    RETURN jsonb_build_object('ok', false, 'error', 'accion_desconocida');
END;
$$;

-- El cierre automático por dato (B2) también saca su foto.
CREATE OR REPLACE FUNCTION recomendaciones_registrar(p_negocio_id   bigint,
                                                     p_ejecucion_id bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_detectadas jsonb;
    v_nuevas     int := 0;
    v_seguian    int := 0;
    v_resueltas  int := 0;
    v_caducadas  int := 0;
    v_vistas     int := 0;
BEGIN
    v_detectadas := recomendaciones_negocio(p_negocio_id, true);


    -- ---- 1. Las que siguen -------------------------------------------------
    -- Se refrescan las cifras: el impacto cambia entre periodos y lo que
    -- interesa mostrar es el de hoy. `detectada_en` NO se toca — es cuándo
    -- empezó el problema, y es media respuesta a "¿desde cuándo vengo así?".
    WITH upd AS (
        UPDATE recomendaciones r
           SET titulo = d.titulo, problema = d.problema, impacto = d.impacto,
               impacto_mes = d.impacto_mes, impacto_tipo = d.impacto_tipo,
               prioridad = d.prioridad, opciones = coalesce(d.opciones, '[]'::jsonb),
               origen_stock = d.origen_stock, icono = d.icono,
               datos = coalesce(d.datos, '{}'::jsonb), revisada_en = now()
          FROM (SELECT * FROM jsonb_to_recordset(v_detectadas) AS e(
                  regla text, clave_objeto text, titulo text, problema text,
                  impacto text, impacto_mes numeric, impacto_tipo text,
                  prioridad text, opciones jsonb, origen_stock text,
                  datos jsonb, icono text, en_informe boolean)) d
         WHERE r.negocio_id = p_negocio_id AND r.regla = d.regla
           AND r.clave_objeto = d.clave_objeto
           AND r.estado IN ('nueva','vigente')
        RETURNING 1)
    SELECT count(*) INTO v_seguian FROM upd;

    -- ---- 2. Las que aparecen por primera vez -------------------------------
    WITH ins AS (
        INSERT INTO recomendaciones (negocio_id, regla, clave_objeto, titulo,
                 problema, impacto, impacto_mes, impacto_tipo, prioridad,
                 opciones, origen_stock, datos, icono, ejecucion_id)
        SELECT p_negocio_id, d.regla, d.clave_objeto, d.titulo, d.problema,
               d.impacto, d.impacto_mes, d.impacto_tipo, d.prioridad,
               coalesce(d.opciones, '[]'::jsonb), d.origen_stock,
               coalesce(d.datos, '{}'::jsonb), d.icono, p_ejecucion_id
        FROM (SELECT * FROM jsonb_to_recordset(v_detectadas) AS e(
                  regla text, clave_objeto text, titulo text, problema text,
                  impacto text, impacto_mes numeric, impacto_tipo text,
                  prioridad text, opciones jsonb, origen_stock text,
                  datos jsonb, icono text, en_informe boolean)) d
        WHERE NOT EXISTS (
            SELECT 1 FROM recomendaciones r
             WHERE r.negocio_id = p_negocio_id AND r.regla = d.regla
               AND r.clave_objeto = d.clave_objeto
               AND r.estado IN ('nueva','vigente'))
        RETURNING 1)
    SELECT count(*) INTO v_nuevas FROM ins;

    -- ---- 3. Las que ya no están --------------------------------------------
    -- >>> 066: la foto de la magnitud ANTES de cerrarlas. Después de cerrar el
    -- valor sigue siendo el mismo, pero el orden explícito evita que un
    -- reordenamiento futuro rompa la medición sin que nadie se entere.
    PERFORM recomendacion_marcar_cierre(re.id)
    FROM recomendaciones re
    WHERE re.negocio_id = p_negocio_id
      AND re.estado IN ('nueva','vigente')
      AND NOT EXISTS (SELECT 1 FROM jsonb_to_recordset(v_detectadas)
                               AS d(regla text, clave_objeto text)
                       WHERE d.regla = re.regla AND d.clave_objeto = re.clave_objeto);

    WITH cerradas AS (
        UPDATE recomendaciones r
           SET estado      = CASE WHEN recomendacion_objeto_evaluable(p_negocio_id, r.clave_objeto)
                                  THEN 'resuelta' ELSE 'caducada' END,
               cerrada_por = CASE WHEN recomendacion_objeto_evaluable(p_negocio_id, r.clave_objeto)
                                  THEN 'dato' ELSE 'sin_datos' END,
               cerrada_en  = now(), revisada_en = now()
         WHERE r.negocio_id = p_negocio_id
           AND r.estado IN ('nueva','vigente')
           -- Basta con esto: el paso 1 solo tocó las que SÍ están detectadas,
           -- así que no hay forma de que una de ellas caiga acá.
           AND NOT EXISTS (SELECT 1 FROM jsonb_to_recordset(v_detectadas)
                                    AS d(regla text, clave_objeto text)
                            WHERE d.regla = r.regla AND d.clave_objeto = r.clave_objeto)
        RETURNING estado)
    SELECT count(*) FILTER (WHERE estado = 'resuelta'),
           count(*) FILTER (WHERE estado = 'caducada')
      INTO v_resueltas, v_caducadas
    FROM cerradas;

    -- ---- 4. Lo que llegó al informe cuenta como visto ----------------------
    -- Solo lo que entró al top 8. Marcar como vista una recomendación que el
    -- dueño nunca leyó dejaría el dato inservible el día que D1 le pregunte
    -- "¿hiciste algo con esto?".
    WITH marcadas AS (
        UPDATE recomendaciones r
           SET estado = 'vigente',
               vista_en = coalesce(r.vista_en, now()),
               veces_vista = r.veces_vista + 1
          FROM (SELECT * FROM jsonb_to_recordset(v_detectadas)
                         AS e(regla text, clave_objeto text, en_informe boolean)) d
         WHERE r.negocio_id = p_negocio_id AND r.regla = d.regla
           AND r.clave_objeto = d.clave_objeto
           AND d.en_informe
           AND r.estado IN ('nueva','vigente')
        RETURNING 1)
    SELECT count(*) INTO v_vistas FROM marcadas;

    RETURN jsonb_build_object('nuevas', v_nuevas, 'seguian', v_seguian,
                              'resueltas', v_resueltas, 'caducadas', v_caducadas,
                              'mostradas', v_vistas);
END;
$$;


-- La medición corre después de cada análisis, con el mismo guardarraíl que el
-- snapshot y el registro: si falla, queda en `fallas` y la ejecución se cierra
-- igual. Un informe entregado vale más que una estadística completa.
CREATE OR REPLACE FUNCTION ejecucion_cerrar(p_ejecucion_id bigint, p_estado text,
                                            p_resultado jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_sesion_id  bigint;
    v_servicio   text;
    v_negocio_id bigint;
    v_chat       bigint;
    v_plantilla  text := 'ejecucion.entregada';
    v_snapshot   bigint;
    v_recos      jsonb;
    v_medido     jsonb;
BEGIN
    UPDATE ejecuciones SET
        estado        = p_estado::estado_ejec,
        texto         = coalesce(p_resultado ->> 'texto', texto),
        tokens_prompt = coalesce((p_resultado ->> 'tokens_prompt')::int, tokens_prompt),
        tokens_salida = coalesce((p_resultado ->> 'tokens_salida')::int, tokens_salida),
        costo         = coalesce((p_resultado ->> 'costo')::numeric, costo),
        pdf           = coalesce(decode(p_resultado ->> 'pdf_base64', 'base64'), pdf),
        error         = p_resultado ->> 'error',
        fin           = now()
    WHERE id = p_ejecucion_id
    RETURNING sesion_id, servicio_codigo, negocio_id
         INTO v_sesion_id, v_servicio, v_negocio_id;

    IF v_sesion_id IS NOT NULL THEN
        SELECT chat_de_usuario(s.usuario_id) INTO v_chat
        FROM sesiones s WHERE s.id = v_sesion_id;

        UPDATE sesiones SET
            estado     = CASE WHEN p_estado = 'completada' THEN 'completada'::estado_sesion
                              ELSE 'fallida'::estado_sesion END,
            cerrada_en = now()
        WHERE id = v_sesion_id;
    END IF;

    IF p_estado = 'completada' AND v_negocio_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM servicios
                    WHERE codigo = v_servicio AND entrada = 'archivos') THEN
        -- >>> 058: la memoria del estado del negocio.
        BEGIN
            v_snapshot := snapshot_tomar(v_negocio_id, 'ejecucion', p_ejecucion_id);
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO fallas (workflow, ejecucion_id, sesion_id, tipo, transitoria, detalle)
            VALUES ('snapshot_tomar', p_ejecucion_id, v_sesion_id, 'permanente', false,
                    jsonb_build_object('mensaje', SQLERRM, 'sqlstate', SQLSTATE));
        END;

        -- >>> 059: la memoria de lo que se le recomendó (R-III).
        BEGIN
            v_recos := recomendaciones_registrar(v_negocio_id, p_ejecucion_id);
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO fallas (workflow, ejecucion_id, sesion_id, tipo, transitoria, detalle)
            VALUES ('recomendaciones_registrar', p_ejecucion_id, v_sesion_id,
                    'permanente', false,
                    jsonb_build_object('mensaje', SQLERRM, 'sqlstate', SQLSTATE));
        END;

        -- >>> 066: ¿sirvió lo que se recomendó antes? Va DESPUÉS del registro
        -- porque el registro es el que cierra por dato, y lo que acaba de
        -- cerrarse ya puede empezar a medirse en la corrida siguiente.
        BEGIN
            v_medido := recomendaciones_medir(v_negocio_id);
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO fallas (workflow, ejecucion_id, sesion_id, tipo, transitoria, detalle)
            VALUES ('recomendaciones_medir', p_ejecucion_id, v_sesion_id,
                    'permanente', false,
                    jsonb_build_object('mensaje', SQLERRM, 'sqlstate', SQLSTATE));
        END;
    END IF;

    IF EXISTS (SELECT 1 FROM plantillas
                WHERE clave = 'ejecucion.entregada.' || coalesce(v_servicio, '—')
                  AND activo) THEN
        v_plantilla := 'ejecucion.entregada.' || v_servicio;
    END IF;

    RETURN jsonb_build_object('ejecucion_id', p_ejecucion_id, 'estado', p_estado,
                              'chat_id', v_chat, 'servicio_codigo', v_servicio,
                              'plantilla_entrega', v_plantilla,
                              'snapshot_id', v_snapshot,
                              'recomendaciones', v_recos,
                              'resultados', v_medido);
END;
$$;


-- =============================================================================
-- 6. El resultado se ve
-- =============================================================================
-- El perfil (B4) contaba cuántas se cerraron y por qué vía. Ahora también dice
-- si sirvieron. `acciones.por_accion` dejó de ser el único indicador de si el
-- ciclo está cerrado: ahora se puede saber si además estaba bien cerrado.
CREATE OR REPLACE FUNCTION perfil_negocio(p_negocio_id bigint)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
      'negocio_id', negocio_id,
      'nombre', nombre,
      'plan', plan,
      'tipo', tipo_nombre,
      'tiene_nit', tiene_nit,
      'periodo', periodo,
      'productos', productos,
      'top_productos', top_productos,
      'proveedores', proveedores,
      'estacionalidad', estacionalidad,
      'problemas_recurrentes', problemas_recurrentes,
      'acciones', acciones,
      -- >>> 066: de lo que se cerró, ¿cuánto sirvió?
      'resultados', (SELECT jsonb_build_object(
                       'positivo', count(*) FILTER (WHERE resultado = 'positivo'),
                       'neutro',   count(*) FILTER (WHERE resultado = 'neutro'),
                       'negativo', count(*) FILTER (WHERE resultado = 'negativo'),
                       'sin_medir', count(*) FILTER (
                          WHERE resultado IS NULL
                            AND estado NOT IN ('nueva','vigente')))
                     FROM recomendaciones WHERE negocio_id = p_negocio_id),
      'salud_historia', salud_historia,
      'calidad', calidad)
    FROM v_perfil_negocio WHERE negocio_id = p_negocio_id;
$$;

-- Y las cerradas dicen cómo les fue, para el portal.
CREATE OR REPLACE FUNCTION portal_recomendaciones(p_limite int DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, pg_temp AS $$
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
$$;

NOTIFY pgrst, 'reload schema';
