CREATE OR REPLACE FUNCTION public.periodo_es(p_desde date, p_hasta date)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT CASE
      WHEN p_desde IS NULL OR p_hasta IS NULL THEN ''
      WHEN p_desde = p_hasta THEN
        format('%s de %s de %s', extract(day from p_desde)::int,
               mes_es(p_desde), extract(year from p_desde)::int)
      WHEN date_trunc('month', p_desde) = date_trunc('month', p_hasta) THEN
        format('del %s al %s de %s de %s', extract(day from p_desde)::int,
               extract(day from p_hasta)::int, mes_es(p_hasta),
               extract(year from p_hasta)::int)
      WHEN extract(year from p_desde) = extract(year from p_hasta) THEN
        format('del %s de %s al %s de %s de %s',
               extract(day from p_desde)::int, mes_es(p_desde),
               extract(day from p_hasta)::int, mes_es(p_hasta),
               extract(year from p_hasta)::int)
      ELSE
        format('del %s de %s de %s al %s de %s de %s',
               extract(day from p_desde)::int, mes_es(p_desde), extract(year from p_desde)::int,
               extract(day from p_hasta)::int, mes_es(p_hasta), extract(year from p_hasta)::int)
    END;
$function$
