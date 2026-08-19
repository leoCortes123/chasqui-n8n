-- 076_lock_de_panel_con_una_clave.sql — la 075 dejó `carga_evaluar` rota.
--
-- El lock se pidió como `pg_advisory_xact_lock(hashtext(...)::bigint,
-- p_sesion_id)`, y esa firma no existe: las dos formas son (bigint) y
-- (int, int). Con dos bigint Postgres no encuentra candidata y la función
-- revienta antes de decidir nada:
--
--   ERROR: function pg_advisory_xact_lock(bigint, bigint) does not exist
--
-- Como `carga_evaluar` es lo que wf_ingesta llama después de cada archivo, con
-- la 075 sola NINGUNA carga habría avanzado: ni panel, ni análisis. Visto al
-- probar el gate contra la sesión 40, antes de cualquier prueba de usuario.
--
-- Se pasa a la firma de un solo argumento con la clave completa —nombre del
-- recurso y sesión— en un bigint, que es lo que se quería desde el principio:
-- dos sesiones distintas no se bloquean entre sí.
--
-- Sin cambios de firma, así que no hay nada que borrar (MIGRACION-001).

CREATE OR REPLACE FUNCTION public.carga_evaluar(p_sesion_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_ses      record;
    v_res      jsonb;
    v_silencio int := coalesce(
        (parametro(NULL, 'carga_silencio_segundos'))::text::int, 10);
    v_vuelo    int := coalesce(
        (parametro(NULL, 'carga_panel_en_vuelo_segundos'))::text::int, 30);
    v_ultimo   timestamptz;
    v_ejec_id  bigint;
BEGIN
    -- Todo lo que sigue decide si sale un mensaje al chat, y con una ráfaga de
    -- archivos hay N ejecuciones acá adentro al mismo tiempo. El lock las
    -- ordena; sin él las N leen el mismo estado y las N mandan panel.
    PERFORM pg_advisory_xact_lock(hashtextextended('carga_panel:' || p_sesion_id, 0));

    -- La sesión se lee DESPUÉS del lock: leerla antes es volver a mirar un
    -- estado que la ejecución de al lado está por cambiar.
    SELECT * INTO v_ses FROM sesiones WHERE id = p_sesion_id;
    IF v_ses.id IS NULL OR v_ses.cerrada_en IS NOT NULL THEN
        RETURN jsonb_build_object('accion', 'nada');
    END IF;

    v_res    := carga_resumen(p_sesion_id);
    v_ultimo := (v_res ->> 'ultimo_en')::timestamptz;

    -- Todavía están llegando: el que entre después se encarga.
    IF v_ultimo IS NOT NULL AND now() - v_ultimo < make_interval(secs => v_silencio) THEN
        RETURN jsonb_build_object('accion', 'nada');
    END IF;

    -- Panel en vuelo: alguien ya lo pidió y Telegram todavía no devolvió el
    -- message_id con el que se edita. Pedir otro es crear un mensaje más.
    IF v_ses.panel_mensaje_id IS NULL
       AND v_ses.panel_pedido_en IS NOT NULL
       AND now() - v_ses.panel_pedido_en < make_interval(secs => v_vuelo) THEN
        RETURN jsonb_build_object('accion', 'nada');
    END IF;

    -- Silencio, y el botón ya estaba tocado.
    IF v_ses.analisis_pedido_en IS NOT NULL AND v_ses.estado = 'recibiendo' THEN
        IF NOT carga_hay_con_que(p_sesion_id) THEN
            UPDATE sesiones SET panel_pedido_en = now() WHERE id = p_sesion_id;
            RETURN jsonb_build_object('accion', 'panel',
                     'panel', carga_panel(p_sesion_id, 'panel'));
        END IF;
        v_ejec_id := carga_arrancar(p_sesion_id);
        IF v_ejec_id IS NULL THEN               -- otro llegó primero
            RETURN jsonb_build_object('accion', 'nada');
        END IF;
        UPDATE sesiones SET panel_pedido_en = now() WHERE id = p_sesion_id;
        RETURN jsonb_build_object('accion', 'analizar', 'ejecucion_id', v_ejec_id,
                 'panel', carga_panel(p_sesion_id, 'analizando'));
    END IF;

    -- Silencio y nadie pidió nada: solo refresco el contador.
    IF v_ses.estado = 'recibiendo' THEN
        UPDATE sesiones SET panel_pedido_en = now() WHERE id = p_sesion_id;
        RETURN jsonb_build_object('accion', 'panel',
                 'panel', carga_panel(p_sesion_id, 'panel'));
    END IF;

    RETURN jsonb_build_object('accion', 'nada');
END;
$function$;
