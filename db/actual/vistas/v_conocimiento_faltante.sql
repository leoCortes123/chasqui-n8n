CREATE OR REPLACE VIEW public.v_conocimiento_faltante AS
 SELECT p.id,
    p.negocio_id,
    n.nombre AS negocio,
    p.pregunta,
    p.veces,
    p.primera_en,
    p.ultima_en,
    s.id AS candidato_id,
    s.titulo AS candidato,
    s.parecido
   FROM conocimiento_pendiente p
     JOIN negocios n ON n.id = p.negocio_id
     LEFT JOIN LATERAL ( SELECT c.id,
            c.titulo,
            round(word_similarity(p.pregunta_norm, norm_texto((c.titulo || ' '::text) || COALESCE(c.contenido, ''::text)))::numeric, 3) AS parecido
           FROM conocimiento c
          WHERE c.negocio_id = p.negocio_id AND word_similarity(p.pregunta_norm, norm_texto((c.titulo || ' '::text) || COALESCE(c.contenido, ''::text))) >= 0.30::double precision
          ORDER BY (round(word_similarity(p.pregunta_norm, norm_texto((c.titulo || ' '::text) || COALESCE(c.contenido, ''::text)))::numeric, 3)) DESC
         LIMIT 1) s ON true
  WHERE p.resuelto_por IS NULL
  ORDER BY p.veces DESC, p.ultima_en DESC;
