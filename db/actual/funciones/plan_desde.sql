CREATE OR REPLACE FUNCTION public.plan_desde(p_negocio_id bigint)
 RETURNS date
 LANGUAGE sql
 STABLE
AS $function$
    SELECT CASE
        WHEN coalesce((SELECT plan FROM negocios WHERE id = p_negocio_id), 'free') <> 'free'
          THEN NULL
        ELSE date_trunc('month', current_date)::date
             - (coalesce((parametro(p_negocio_id, 'plan_free_meses_historia'))::text::int, 3) - 1)
               * interval '1 month'
    END::date;
$function$
