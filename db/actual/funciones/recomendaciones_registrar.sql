CREATE OR REPLACE FUNCTION public.recomendaciones_registrar(p_negocio_id bigint, p_ejecucion_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
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
$function$
