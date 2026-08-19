CREATE OR REPLACE FUNCTION public.contexto_negocio_recuperar(p_negocio_id bigint, p_contexto jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_pregunta text := btrim(coalesce(p_contexto ->> 'pregunta', ''));
    v_perfil   jsonb := perfil_negocio(p_negocio_id);
    v_hechos   jsonb := conocimiento_buscar(p_negocio_id, v_pregunta);
BEGIN
    RETURN jsonb_build_object(
        'negocio_id', p_negocio_id,
        'generado_en', now(),
        'pregunta', v_pregunta,

        -- La KB, tal cual. No se toca: cuando la pregunta es por un precio o
        -- por el horario, lo que alguien escribió a mano le gana a cualquier
        -- agregado.
        'hechos', coalesce(v_hechos, '[]'::jsonb),

        -- >>> 063: si la pregunta pide un número puntual, acá está calculado.
        -- NULL cuando ninguna intención coincide.
        'consulta', intencion_resolver(p_negocio_id, v_pregunta),

        -- >>> 062: los números, que es lo que faltaba.
        'negocio', jsonb_build_object(
            'tipo',            v_perfil -> 'tipo',
            'periodo',         v_perfil -> 'periodo',
            'productos',       v_perfil -> 'productos',
            'top_productos',   v_perfil -> 'top_productos',
            'proveedores',     v_perfil -> 'proveedores',
            'estacionalidad',  v_perfil -> 'estacionalidad',
            'problemas_recurrentes', v_perfil -> 'problemas_recurrentes',
            'acciones',        v_perfil -> 'acciones',
            'calidad',         v_perfil -> 'calidad'),

        'estado', salud_negocio(p_negocio_id),
        'comparativo', hallazgos_comparativo(p_negocio_id),
        'recomendaciones', recomendaciones_vigentes(p_negocio_id, 8),

        'encabezado', jsonb_build_object(
            'titulo', 'Tu pregunta',
            'subtitulo', v_pregunta,
            'metricas', '[]'::jsonb));
END;
$function$
