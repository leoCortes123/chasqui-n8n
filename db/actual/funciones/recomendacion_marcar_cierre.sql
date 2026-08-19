CREATE OR REPLACE FUNCTION public.recomendacion_marcar_cierre(p_reco_id bigint)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
$function$
