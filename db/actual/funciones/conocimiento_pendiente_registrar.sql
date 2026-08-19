CREATE OR REPLACE FUNCTION public.conocimiento_pendiente_registrar(p_negocio_id bigint, p_pregunta text)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_norm text := norm_pregunta(p_pregunta);
    v_id   bigint;
BEGIN
    IF p_negocio_id IS NULL OR v_norm = '' THEN RETURN NULL; END IF;

    INSERT INTO conocimiento_pendiente (negocio_id, pregunta, pregunta_norm)
    VALUES (p_negocio_id, btrim(p_pregunta), v_norm)
    ON CONFLICT (negocio_id, pregunta_norm) DO UPDATE
      SET veces = conocimiento_pendiente.veces + 1, ultima_en = now()
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$function$
