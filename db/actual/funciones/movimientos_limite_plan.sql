CREATE OR REPLACE FUNCTION public.movimientos_limite_plan()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE v_desde date;
BEGIN
    IF NEW.fecha IS NULL THEN RETURN NEW; END IF;

    v_desde := plan_desde(NEW.negocio_id);
    IF v_desde IS NULL OR NEW.fecha >= v_desde THEN RETURN NEW; END IF;

    IF NEW.documento_id IS NOT NULL THEN
        UPDATE documentos SET filas_fuera_de_plan = filas_fuera_de_plan + 1
        WHERE id = NEW.documento_id;
    END IF;
    RETURN NEW;   -- fuera de la ventana de LECTURA, pero se guarda igual
END;
$function$
