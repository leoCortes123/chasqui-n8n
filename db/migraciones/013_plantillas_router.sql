-- 013_plantillas_router.sql — textos que usa router_procesar_mensaje.
INSERT INTO plantillas (clave, cuerpo, variables) VALUES
  ('sistema.elegir_servicio',
   '¿Qué análisis necesitas? Elige uno:' || E'\n{{lista}}\n\nEscribe el nombre del que quieras.',
   '["lista"]'),
  ('sistema.servicio_no_reconocido',
   'No reconocí ese servicio. Escribe el nombre tal como aparece en la lista, por favor.',
   '[]'),
  ('sistema.pedir_archivos',
   'Perfecto, *{{servicio}}*. Envíame los archivos (facturas XML de la DIAN y/o el CSV de ventas de tu POS). Cuando termines, escribe */listo*.',
   '["servicio"]'),
  ('sistema.sin_sesion',
   'No tienes un análisis en curso. Escribe */nueva* para empezar uno.',
   '[]'),
  ('sistema.sin_documentos',
   'Todavía no recibí ningún archivo válido. Envíame al menos uno y luego */listo*.',
   '[]'),
  ('sistema.esperando_listo',
   'Recibido. Sigue enviando archivos o escribe */listo* cuando termines.',
   '[]'),
  ('sistema.no_entendido',
   'No te entendí. Escribe */nueva* para un análisis nuevo o */ayuda* para ver qué puedo hacer.',
   '[]')
ON CONFLICT (clave) DO NOTHING;
