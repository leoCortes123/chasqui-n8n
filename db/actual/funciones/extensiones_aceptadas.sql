CREATE OR REPLACE FUNCTION public.extensiones_aceptadas()
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
    SELECT string_agg(DISTINCT upper(ext), ', ' ORDER BY upper(ext))
    FROM (
        SELECT jsonb_object_keys(parametro(NULL, 'ingesta_extractores')) AS ext
        UNION
        SELECT unnest(extensiones) FROM formatos_documento
         WHERE activo AND clase = 'documento'
    ) t;
$function$
