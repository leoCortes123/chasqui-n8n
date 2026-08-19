CREATE OR REPLACE FUNCTION public.router_arranque_servicio(p_negocio_id bigint, p_chat_id bigint, p_servicio text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_nombre text;
    v_tipo   text;
BEGIN
    SELECT nombre INTO v_nombre FROM servicios WHERE codigo = p_servicio;
    SELECT nullif(btrim(coalesce(tipo, '')), '') INTO v_tipo
    FROM negocios WHERE id = p_negocio_id;

    -- Sin negocio asignado no hay dónde guardar el tipo: no se pregunta lo que
    -- no se puede responder.
    IF p_negocio_id IS NOT NULL AND v_tipo IS NULL THEN
        RETURN router_respuesta(p_chat_id, 'sistema.pedir_tipo',
                 '{}'::jsonb, teclado_tipos_negocio());
    END IF;

    IF p_servicio = 'mercado_compras' THEN
        RETURN mercado_compras_bienvenida(p_negocio_id, p_chat_id);
    END IF;

    RETURN router_respuesta(p_chat_id, 'sistema.pedir_archivos',
             jsonb_build_object('servicio', v_nombre,
                                'formatos', extensiones_aceptadas()));
END;
$function$
