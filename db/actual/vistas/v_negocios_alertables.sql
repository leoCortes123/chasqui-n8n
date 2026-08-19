CREATE OR REPLACE VIEW public.v_negocios_alertables AS
 SELECT n.id AS negocio_id,
    u.id AS usuario_id,
    u.telegram_chat_id AS chat_id,
    m.ultimo_dato,
    e.ultimo_analisis
   FROM negocios n
     JOIN LATERAL ( SELECT usuarios.id,
            usuarios.telegram_chat_id
           FROM usuarios
          WHERE usuarios.negocio_id = n.id AND usuarios.autorizacion_datos AND usuarios.telegram_chat_id IS NOT NULL
          ORDER BY usuarios.id
         LIMIT 1) u ON true
     CROSS JOIN LATERAL ( SELECT max(mov_visibles.creado_en) AS ultimo_dato
           FROM mov_visibles
          WHERE mov_visibles.negocio_id = n.id) m
     CROSS JOIN LATERAL ( SELECT max(ejecuciones.fin) AS ultimo_analisis
           FROM ejecuciones
          WHERE ejecuciones.negocio_id = n.id AND ejecuciones.estado = 'completada'::estado_ejec AND (ejecuciones.servicio_codigo IN ( SELECT servicios.codigo
                   FROM servicios
                  WHERE servicios.entrada = 'archivos'::text))) e
  WHERE m.ultimo_dato IS NOT NULL AND (e.ultimo_analisis IS NULL OR m.ultimo_dato > e.ultimo_analisis);
