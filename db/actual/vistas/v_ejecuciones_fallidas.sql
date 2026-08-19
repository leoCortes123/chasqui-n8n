CREATE OR REPLACE VIEW public.v_ejecuciones_fallidas AS
 SELECT id AS ejecucion_id,
    negocio_id,
    servicio_codigo,
    error,
    inicio,
    fin
   FROM ejecuciones e
  WHERE estado = 'fallida'::estado_ejec AND inicio >= (now() - '24:00:00'::interval)
  ORDER BY inicio DESC;
