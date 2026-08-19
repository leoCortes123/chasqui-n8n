CREATE OR REPLACE FUNCTION public.tercero_obtener(p_negocio_id bigint, p_nit text, p_nombre text)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_nit text := nullif(btrim(coalesce(p_nit, '')), '');
    v_id  bigint;
BEGIN
    IF v_nit IS NOT NULL THEN
        SELECT id INTO v_id FROM terceros
        WHERE negocio_id = p_negocio_id AND nit = v_nit;
    ELSE
        SELECT id INTO v_id FROM terceros
        WHERE negocio_id = p_negocio_id AND nit IS NULL
          AND norm_texto(nombre) = norm_texto(p_nombre);
    END IF;

    IF v_id IS NULL THEN
        INSERT INTO terceros (negocio_id, nit, nombre)
        VALUES (p_negocio_id, v_nit, coalesce(nullif(btrim(p_nombre), ''), '(sin nombre)'))
        RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END;
$function$
