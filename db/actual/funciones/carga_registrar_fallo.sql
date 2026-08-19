CREATE OR REPLACE FUNCTION public.carga_registrar_fallo(p_sesion_id bigint, p_nombre text)
 RETURNS void
 LANGUAGE sql
AS $function$
    UPDATE sesiones
       SET contexto = jsonb_set(contexto, '{descargas_fallidas}',
             coalesce(contexto -> 'descargas_fallidas', '[]'::jsonb)
               || to_jsonb(coalesce(nullif(btrim(p_nombre), ''), 'un archivo')),
             true)
     WHERE id = p_sesion_id;
$function$
