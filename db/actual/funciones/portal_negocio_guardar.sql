CREATE OR REPLACE FUNCTION public.portal_negocio_guardar(p_nit text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_negocio bigint := portal_negocio();
    v_crudo   text := regexp_replace(coalesce(p_nit, ''), '[.\s]', '', 'g');
    v_base    text;
    v_dv      text;
BEGIN
    -- Borrar el NIT es legítimo (se escribió mal, el negocio cambió de figura).
    IF v_crudo = '' THEN
        UPDATE negocios SET nit = NULL WHERE id = v_negocio;
        RETURN jsonb_build_object('ok', true, 'nit', NULL);
    END IF;

    v_base := split_part(v_crudo, '-', 1);
    v_dv   := nullif(split_part(v_crudo, '-', 2), '');

    IF v_base !~ '^\d{5,15}$' THEN
        RETURN jsonb_build_object('ok', false, 'error',
                 'El NIT debe tener solo números (entre 5 y 15 dígitos), con o sin -DV.');
    END IF;

    IF v_dv IS NOT NULL AND v_dv <> nit_dv(v_base)::text THEN
        RETURN jsonb_build_object('ok', false, 'error',
                 format('El dígito de verificación no cuadra: para %s sería %s.',
                        v_base, nit_dv(v_base)));
    END IF;

    UPDATE negocios SET nit = v_base WHERE id = v_negocio;

    -- Con el NIT nuevo, las facturas DIAN ya ingeridas pueden cambiar de lado
    -- (compra -> venta). Se re-facturan acá mismo: es la misma función del
    -- backfill de la 036, actualiza en vez de duplicar y conserva los pagos.
    PERFORM cartera_refacturar(v_negocio);

    RETURN jsonb_build_object('ok', true, 'nit', v_base, 'dv', nit_dv(v_base));
END;
$function$
