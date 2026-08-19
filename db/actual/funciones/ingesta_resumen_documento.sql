CREATE OR REPLACE FUNCTION public.ingesta_resumen_documento(p_documento_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT jsonb_build_object(
        'nombre_archivo', d.nombre_archivo,
        'formato',        d.formato_codigo,
        'estado',         d.estado,
        'error',          d.error,
        'filas',          (SELECT count(*) FROM movimientos m WHERE m.documento_id = d.id),
        'desde',          (SELECT min(fecha) FROM movimientos m WHERE m.documento_id = d.id),
        'hasta',          (SELECT max(fecha) FROM movimientos m WHERE m.documento_id = d.id),
        'total',          (SELECT round(coalesce(sum(valor_total),0)) FROM movimientos m WHERE m.documento_id = d.id),
        'productos',      (SELECT count(DISTINCT coalesce(m.raw ->> 'producto', m.raw ->> 'descripcion'))
                             FROM movimientos m WHERE m.documento_id = d.id),
        'sin_resolver',   (SELECT count(*) FROM movimientos m
                            WHERE m.documento_id = d.id AND m.producto_id IS NULL),
        -- >>> nuevo respecto a la 017: si este documento generó factura y el
        -- negocio no tiene NIT, no se pudo saber de qué lado del mostrador está.
        'aviso_nit',      CASE WHEN EXISTS (SELECT 1 FROM facturas f WHERE f.documento_id = d.id)
                                AND (SELECT nullif(btrim(coalesce(n.nit, '')), '')
                                       FROM negocios n WHERE n.id = d.negocio_id) IS NULL
                          THEN ' 💡 La tomé como compra porque no tengo el NIT de tu negocio. Cargalo en tu /portal (Mi negocio) y sabré cuáles facturas son tuyas (te deben) y cuáles recibís (debés).'
                          ELSE '' END
    )
    FROM documentos d WHERE d.id = p_documento_id;
$function$
