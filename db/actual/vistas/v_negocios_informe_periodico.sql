CREATE OR REPLACE VIEW public.v_negocios_informe_periodico AS
 SELECT n.id AS negocio_id,
    u.id AS usuario_id,
    u.telegram_chat_id AS chat_id,
    e.ultimo_analisis,
    m.movs_nuevos
   FROM negocios n
     JOIN LATERAL ( SELECT usuarios.id,
            usuarios.telegram_chat_id
           FROM usuarios
          WHERE usuarios.negocio_id = n.id AND usuarios.autorizacion_datos AND usuarios.telegram_chat_id IS NOT NULL
          ORDER BY usuarios.id
         LIMIT 1) u ON true
     CROSS JOIN LATERAL ( SELECT max(ejecuciones.fin) AS ultimo_analisis
           FROM ejecuciones
          WHERE ejecuciones.negocio_id = n.id AND ejecuciones.estado = 'completada'::estado_ejec AND (ejecuciones.servicio_codigo IN ( SELECT servicios.codigo
                   FROM servicios
                  WHERE servicios.entrada = 'archivos'::text))) e
     CROSS JOIN LATERAL ( SELECT count(*) AS movs_nuevos
           FROM mov_visibles
          WHERE mov_visibles.negocio_id = n.id AND (e.ultimo_analisis IS NULL OR mov_visibles.creado_en > e.ultimo_analisis)) m
  WHERE e.ultimo_analisis IS NOT NULL AND e.ultimo_analisis < (now() - make_interval(days => COALESCE(parametro(NULL::bigint, 'informe_periodico_dias'::text)::text::integer, 30))) AND m.movs_nuevos >= COALESCE(parametro(NULL::bigint, 'informe_periodico_min_movs'::text)::text::integer, 10) AND NOT (EXISTS ( SELECT 1
           FROM ejecuciones x
          WHERE x.negocio_id = n.id AND (x.estado = ANY (ARRAY['preparando'::estado_ejec, 'procesando'::estado_ejec, 'validando'::estado_ejec]))));
