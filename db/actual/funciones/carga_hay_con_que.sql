CREATE OR REPLACE FUNCTION public.carga_hay_con_que(p_sesion_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
    SELECT EXISTS (SELECT 1 FROM documentos
                    WHERE sesion_id = p_sesion_id AND estado = 'parseado')
        OR EXISTS (SELECT 1 FROM sesiones s
                    WHERE s.id = p_sesion_id
                      AND s.servicio_codigo = 'mercado_compras'
                      AND EXISTS (SELECT 1 FROM mov_visibles v
                                   WHERE v.negocio_id = s.negocio_id
                                     AND v.tipo = 'compra'));
$function$
