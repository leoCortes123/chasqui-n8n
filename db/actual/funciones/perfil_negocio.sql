CREATE OR REPLACE FUNCTION public.perfil_negocio(p_negocio_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT jsonb_build_object(
      'negocio_id', negocio_id,
      'nombre', nombre,
      'plan', plan,
      'tipo', tipo_nombre,
      'tiene_nit', tiene_nit,
      'periodo', periodo,
      'productos', productos,
      'top_productos', top_productos,
      'proveedores', proveedores,
      'estacionalidad', estacionalidad,
      'problemas_recurrentes', problemas_recurrentes,
      'acciones', acciones,
      -- >>> 066: de lo que se cerró, ¿cuánto sirvió?
      'resultados', (SELECT jsonb_build_object(
                       'positivo', count(*) FILTER (WHERE resultado = 'positivo'),
                       'neutro',   count(*) FILTER (WHERE resultado = 'neutro'),
                       'negativo', count(*) FILTER (WHERE resultado = 'negativo'),
                       'sin_medir', count(*) FILTER (
                          WHERE resultado IS NULL
                            AND estado NOT IN ('nueva','vigente')))
                     FROM recomendaciones WHERE negocio_id = p_negocio_id),
      'salud_historia', salud_historia,
      'calidad', calidad)
    FROM v_perfil_negocio WHERE negocio_id = p_negocio_id;
$function$
