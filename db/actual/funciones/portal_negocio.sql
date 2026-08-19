CREATE OR REPLACE FUNCTION public.portal_negocio()
 RETURNS bigint
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE v_id bigint := portal_claim('negocio_id');
BEGIN
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'sesión sin negocio' USING ERRCODE = '42501';
    END IF;
    RETURN v_id;
END;
$function$
