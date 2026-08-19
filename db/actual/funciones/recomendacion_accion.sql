CREATE OR REPLACE FUNCTION public.recomendacion_accion(p_reco_id bigint, p_negocio_id bigint, p_accion text, p_usuario_id bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
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
$function$
