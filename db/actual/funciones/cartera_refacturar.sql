CREATE OR REPLACE FUNCTION public.cartera_refacturar(p_negocio_id bigint)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE r record;
BEGIN
    FOR r IN SELECT id FROM documentos
             WHERE negocio_id = p_negocio_id
               AND formato_codigo = 'dian_xml' AND estado = 'parseado' LOOP
        BEGIN
            PERFORM cartera_facturar_dian(r.id);
        EXCEPTION WHEN OTHERS THEN
            -- un XML viejo ilegible no debe frenar el cambio de NIT
            NULL;
        END;
    END LOOP;
END;
$function$
