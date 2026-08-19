CREATE OR REPLACE VIEW public.v_salud_ingesta AS
 WITH por_estado AS (
         SELECT documentos.negocio_id,
            documentos.formato_codigo,
            documentos.estado,
            count(*) AS documentos
           FROM documentos
          GROUP BY documentos.negocio_id, documentos.formato_codigo, documentos.estado
        )
 SELECT negocio_id,
    formato_codigo,
    estado,
    documentos,
    round(100.0 * sum(documentos) FILTER (WHERE estado = 'error'::estado_doc) OVER (PARTITION BY negocio_id, formato_codigo) / NULLIF(sum(documentos) OVER (PARTITION BY negocio_id, formato_codigo), 0::numeric), 1) AS pct_error_formato
   FROM por_estado
  ORDER BY negocio_id, formato_codigo, estado;
