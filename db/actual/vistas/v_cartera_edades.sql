CREATE OR REPLACE VIEW public.v_cartera_edades AS
 SELECT negocio_id,
    tipo,
        CASE
            WHEN vencimiento IS NULL OR vencimiento >= CURRENT_DATE THEN 'al_dia'::text
            WHEN (CURRENT_DATE - vencimiento) <= 30 THEN 'd1_30'::text
            WHEN (CURRENT_DATE - vencimiento) <= 60 THEN 'd31_60'::text
            WHEN (CURRENT_DATE - vencimiento) <= 90 THEN 'd61_90'::text
            ELSE 'd90_mas'::text
        END AS edad,
    count(*) AS facturas,
    sum(saldo) AS saldo
   FROM facturas
  WHERE saldo > 0::numeric
  GROUP BY negocio_id, tipo, (
        CASE
            WHEN vencimiento IS NULL OR vencimiento >= CURRENT_DATE THEN 'al_dia'::text
            WHEN (CURRENT_DATE - vencimiento) <= 30 THEN 'd1_30'::text
            WHEN (CURRENT_DATE - vencimiento) <= 60 THEN 'd31_60'::text
            WHEN (CURRENT_DATE - vencimiento) <= 90 THEN 'd61_90'::text
            ELSE 'd90_mas'::text
        END);
