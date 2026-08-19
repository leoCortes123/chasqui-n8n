CREATE OR REPLACE FUNCTION public.recomendacion_objeto_evaluable(p_negocio_id bigint, p_clave text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
    SELECT CASE
      WHEN p_clave = 'negocio' THEN EXISTS (
             SELECT 1 FROM mov_visibles WHERE negocio_id = p_negocio_id)
      WHEN p_clave LIKE 'producto:%' THEN EXISTS (
             SELECT 1 FROM mov_visibles
              WHERE negocio_id = p_negocio_id
                AND producto_id = nullif(split_part(p_clave, ':', 2), '')::bigint)
      WHEN p_clave LIKE 'proveedor:%' THEN EXISTS (
             SELECT 1 FROM mov_visibles
              WHERE negocio_id = p_negocio_id AND tipo = 'compra'
                AND btrim(coalesce(raw ->> 'proveedor', '')) = substring(p_clave FROM 11))
      -- >>> 069: el tercero sigue siendo evaluable mientras exista como
      -- tercero, tenga o no facturas abiertas. Que ya no deba nada es
      -- justamente el caso "se resolvió".
      WHEN p_clave LIKE 'tercero:%' THEN EXISTS (
             SELECT 1 FROM terceros
              WHERE negocio_id = p_negocio_id
                AND id = nullif(split_part(p_clave, ':', 2), '')::bigint)
      ELSE false
    END;
$function$
