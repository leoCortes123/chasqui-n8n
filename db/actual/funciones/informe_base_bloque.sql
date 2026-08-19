CREATE OR REPLACE FUNCTION public.informe_base_bloque(p_hallazgos jsonb, p_servicio text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_neg      bigint := (p_hallazgos ->> 'negocio_id')::bigint;
    v_lineas   text[] := '{}';
    v_archivos bigint;
    v_vis      bigint;
    v_total    bigint;
    v_ocultos  bigint;
    v_ventas   bigint;
    v_compras  bigint;
    v_desde    date;
    v_hasta    date;
    v_sin_nit  boolean;
BEGIN
    IF v_neg IS NULL THEN RETURN NULL; END IF;

    SELECT count(DISTINCT m.documento_id) FILTER (WHERE m.documento_id IS NOT NULL),
           count(*)
      INTO v_archivos, v_total
    FROM movimientos m WHERE m.negocio_id = v_neg;

    IF v_total = 0 THEN RETURN NULL; END IF;

    SELECT count(*),
           count(*) FILTER (WHERE tipo = 'venta'),
           count(*) FILTER (WHERE tipo = 'compra'),
           min(fecha), max(fecha)
      INTO v_vis, v_ventas, v_compras, v_desde, v_hasta
    FROM mov_visibles WHERE negocio_id = v_neg;

    v_ocultos := v_total - v_vis;

    v_lineas := v_lineas || format('📄 Salió de <b>%s</b> %s tuyos: <b>%s</b> %s.',
        miles(v_archivos), CASE WHEN v_archivos = 1 THEN 'archivo' ELSE 'archivos' END,
        miles(v_vis), CASE WHEN v_vis = 1 THEN 'registro' ELSE 'registros' END);

    -- Ventas y compras por separado. El caso de cero se dice con todas las
    -- letras porque es el que invalida medio informe.
    IF v_ventas = 0 THEN
        v_lineas := v_lineas ||
          '⚠️ <b>No tengo ninguna venta tuya.</b> Sin ventas no puedo calcular '
          'margen, rotación ni qué te deja plata: esto es solo lo que se ve '
          'desde tus compras.'::text;
    ELSIF v_compras = 0 THEN
        v_lineas := v_lineas ||
          '⚠️ <b>No tengo ninguna compra tuya.</b> Sin compras no puedo calcular '
          'margen ni costos: esto es solo lo que se ve desde tus ventas.'::text;
    ELSE
        v_lineas := v_lineas || format('🧾 %s de venta · %s de compra.',
            miles(v_ventas), miles(v_compras));
    END IF;

    -- Lo que está guardado y el plan no deja mirar. Decirlo es la diferencia
    -- entre "no tengo tus datos" y "tengo tus datos y te muestro esta parte".
    IF v_ocultos > 0 THEN
        v_lineas := v_lineas || format(
          '🔒 Tengo <b>%s</b> registros más guardados, fuera de la ventana de tu '
          'plan. No los perdés: mirá /plan.', miles(v_ocultos));
    END IF;

    SELECT (nullif(btrim(coalesce(n.nit, '')), '') IS NULL
            AND EXISTS (SELECT 1 FROM facturas f WHERE f.negocio_id = n.id))
      INTO v_sin_nit
    FROM negocios n WHERE n.id = v_neg;

    IF coalesce(v_sin_nit, false) THEN
        v_lineas := v_lineas ||
          '💡 Tus facturas las tomé todas como compras porque no tengo el NIT de '
          'tu negocio. Cargalo en /portal y voy a saber cuáles son ventas tuyas.'::text;
    END IF;

    RETURN replace(
             plantilla_cuerpo_srv('informe.base', p_servicio,
               E'🧮 <b>Sobre qué calculé esto</b>\n{{lineas}}'),
             '{{lineas}}', array_to_string(v_lineas, E'\n'));
END;
$function$
