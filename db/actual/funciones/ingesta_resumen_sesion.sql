CREATE OR REPLACE FUNCTION public.ingesta_resumen_sesion(p_sesion_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    WITH docs AS (
        SELECT d.id, d.nombre_archivo, d.filas_fuera_de_plan,
               (SELECT count(*) FROM movimientos m WHERE m.documento_id = d.id) AS filas,
               (SELECT round(coalesce(sum(m.valor_total), 0))
                  FROM movimientos m WHERE m.documento_id = d.id)               AS total
        FROM documentos d
        WHERE d.sesion_id = p_sesion_id AND d.estado = 'parseado'
    ),
    fuera AS (SELECT coalesce(sum(filas_fuera_de_plan), 0)::int AS n FROM docs),
    -- >>> 046, restaurado por 057. Mira `movimientos` y no `mov_visibles` a
    -- propósito: informa qué trajo el archivo, que es lo honesto — el mismo
    -- criterio por el que la 053 dejó esta función fuera del repunte a
    -- `mov_visibles`. Lo que el plan todavía no analiza lo dice `aviso_plan`.
    rango AS (
        SELECT min(m.fecha) AS desde, max(m.fecha) AS hasta
        FROM movimientos m
        JOIN documentos d ON d.id = m.documento_id
        WHERE d.sesion_id = p_sesion_id AND m.fecha IS NOT NULL
    )
    SELECT jsonb_build_object(
        'archivos', (SELECT count(*) FROM docs),
        'detalle',  coalesce((SELECT string_agg(
                        format('📄 %s: %s registros, $%s',
                               nombre_archivo, filas, miles(total)),
                        E'\n' ORDER BY id) FROM docs), ''),
        'total',    '$' || miles((SELECT coalesce(sum(total), 0) FROM docs)),

        -- Periodo de facturación cubierto, y el aviso cuando es corto: es el
        -- momento de mandar más, no después de ver un informe flojo.
        'periodo', coalesce((SELECT E'\n📅 Periodo de facturación: '
                                    || periodo_es(desde, hasta)
                                    || CASE WHEN hasta - desde < 80
                                            THEN ' — es poco tiempo; si tenés más meses, mandámelos y el análisis sale mucho mejor.'
                                            ELSE '' END
                             FROM rango WHERE desde IS NOT NULL), ''),

        'aviso_nit', CASE WHEN EXISTS (
                            SELECT 1 FROM facturas f
                            JOIN documentos d ON d.id = f.documento_id
                            WHERE d.sesion_id = p_sesion_id)
                          AND (SELECT nullif(btrim(coalesce(n.nit, '')), '')
                                 FROM negocios n
                                 JOIN sesiones s ON s.negocio_id = n.id
                                WHERE s.id = p_sesion_id) IS NULL
                     THEN E'\n\n💡 Las facturas las tomé como compras porque no tengo el NIT de tu negocio. Cargalo en tu /portal (Mi negocio) y sabré cuáles son tuyas.'
                     ELSE '' END,
        -- >>> 053: lo que el plan gratuito todavía no analiza. Se guardó todo.
        'aviso_plan', CASE WHEN (SELECT n FROM fuera) > 0
                     THEN format(E'\n\n🎁 Guardé %s registros más viejos que %s meses, pero todavía no los analizo: el plan gratuito cubre esa ventana. Están ahí esperando —si ampliás el plan entran al análisis solos, sin volver a mandarme nada—. Mirá /plan.',
                                 (SELECT n FROM fuera),
                                 coalesce((parametro(NULL, 'plan_free_meses_historia'))::text, '3'))
                     ELSE '' END
    );
$function$
