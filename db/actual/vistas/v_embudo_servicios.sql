CREATE OR REPLACE VIEW public.v_embudo_servicios AS
 SELECT servicio_codigo,
    count(*) AS iniciadas,
    count(*) FILTER (WHERE estado = 'completada'::estado_sesion) AS completadas,
    count(*) FILTER (WHERE estado = 'expirada'::estado_sesion) AS abandonadas,
    count(*) FILTER (WHERE estado = 'fallida'::estado_sesion) AS fallidas,
    mode() WITHIN GROUP (ORDER BY paso) FILTER (WHERE estado = ANY (ARRAY['expirada'::estado_sesion, 'fallida'::estado_sesion])) AS paso_de_caida
   FROM sesiones
  GROUP BY servicio_codigo;
