CREATE OR REPLACE FUNCTION public.carga_arrancar(p_sesion_id bigint)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_ses     record;
    v_ejec_id bigint;
BEGIN
    UPDATE sesiones SET estado = 'procesando', paso = 'ejecutando'
    WHERE id = p_sesion_id AND estado = 'recibiendo' AND cerrada_en IS NULL
    RETURNING * INTO v_ses;

    IF v_ses.id IS NULL THEN RETURN NULL; END IF;

    INSERT INTO ejecuciones (sesion_id, negocio_id, servicio_codigo, estado)
    VALUES (v_ses.id, v_ses.negocio_id, v_ses.servicio_codigo, 'preparando')
    RETURNING id INTO v_ejec_id;

    RETURN v_ejec_id;
END;
$function$
