CREATE OR REPLACE FUNCTION public.router_plan(p_negocio_id bigint, p_chat_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_plan   text;
    c        record;
    v_pct    numeric := 0;
    v_enlace text;
    v_aviso_cupo text := '';
    v_aviso_pago text := '';
BEGIN
    -- Sin negocio asignado no hay plan que mostrar.
    IF p_negocio_id IS NULL THEN
        RETURN router_respuesta(p_chat_id, 'sistema.no_entendido');
    END IF;

    SELECT plan INTO v_plan FROM negocios WHERE id = p_negocio_id;
    SELECT * INTO c FROM v_consumo_negocio WHERE negocio_id = p_negocio_id;

    IF c.cupo_tokens_mes > 0 THEN
        v_pct := round(100.0 * c.tokens_mes / c.cupo_tokens_mes);
    END IF;

    -- cupo 0 = bloqueado (regla de la 001); pasado el 80% se avisa antes de
    -- que ejecucion_preparar empiece a bloquear.
    IF c.cupo_tokens_mes = 0 THEN
        v_aviso_cupo := E'\n\n⛔ El servicio está suspendido para tu negocio.';
    ELSIF v_pct >= 100 THEN
        v_aviso_cupo := E'\n\n⛔ Superaste el cupo del mes: los análisis quedan bloqueados hasta el próximo mes o hasta ampliar el plan.';
    ELSIF v_pct >= 80 THEN
        v_aviso_cupo := E'\n\n⚠️ Vas por el ' || v_pct || '% del cupo del mes.';
    END IF;

    v_enlace := btrim(coalesce(parametro(p_negocio_id, 'pago_enlace') #>> '{}', ''));
    IF v_enlace <> '' THEN
        v_aviso_pago := E'\n\n💳 <a href="' || v_enlace ||
                        '">Pagar o ampliar el plan</a> (te lleva a Wompi, pago seguro).';
    END IF;

    RETURN router_respuesta(p_chat_id, 'plan.estado', jsonb_build_object(
        'plan', coalesce(v_plan, 'free'),
        'ejecuciones', coalesce(c.ejecuciones_mes, 0),
        'tokens', miles(coalesce(c.tokens_mes, 0)),
        'cupo', miles(coalesce(c.cupo_tokens_mes, 0)),
        'pct', v_pct,
        'aviso_cupo', v_aviso_cupo,
        'aviso_pago', v_aviso_pago));
END;
$function$
