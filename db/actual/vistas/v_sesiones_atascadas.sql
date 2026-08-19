CREATE OR REPLACE VIEW public.v_sesiones_atascadas AS
 SELECT id AS sesion_id,
    negocio_id,
    servicio_codigo,
    paso,
    estado,
    ultima_actividad,
    now() - ultima_actividad AS antiguedad
   FROM sesiones s
  WHERE cerrada_en IS NULL
  ORDER BY ultima_actividad;
