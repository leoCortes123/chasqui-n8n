CREATE OR REPLACE VIEW public.v_consumo_negocio AS
 SELECT n.id AS negocio_id,
    n.nombre,
    n.cupo_tokens_mes,
    COALESCE(sum(e.tokens_prompt + e.tokens_salida) FILTER (WHERE e.inicio >= date_trunc('month'::text, now())), 0::bigint) AS tokens_mes,
    COALESCE(sum(e.costo) FILTER (WHERE e.inicio >= date_trunc('month'::text, now())), 0::numeric) AS costo_mes,
    count(e.id) FILTER (WHERE e.inicio >= date_trunc('month'::text, now()) AND e.estado = 'completada'::estado_ejec) AS ejecuciones_mes
   FROM negocios n
     LEFT JOIN ejecuciones e ON e.negocio_id = n.id
  GROUP BY n.id, n.nombre, n.cupo_tokens_mes;
