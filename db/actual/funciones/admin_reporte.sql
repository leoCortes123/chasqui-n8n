CREATE OR REPLACE FUNCTION public.admin_reporte(p_cmd text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE v text;
BEGIN
    IF p_cmd = '/salud' THEN
        SELECT coalesce(string_agg(format('%s/%s · %s: %s docs (err %s%%)',
                 negocio_id, formato_codigo, estado, documentos,
                 coalesce(pct_error_formato,0)), E'\n'), 'sin documentos')
        INTO v FROM v_salud_ingesta;
        RETURN '🩺 *Salud de ingesta*' || E'\n' || v;

    ELSIF p_cmd = '/embudo' THEN
        SELECT coalesce(string_agg(format('%s: %s iniciadas, %s completas, %s abandonadas, %s fallidas (cae en: %s)',
                 servicio_codigo, iniciadas, completadas, abandonadas, fallidas,
                 coalesce(paso_de_caida,'-')), E'\n'), 'sin sesiones')
        INTO v FROM v_embudo_servicios;
        RETURN '🫗 *Embudo de servicios*' || E'\n' || v;

    ELSIF p_cmd = '/fallas' THEN
        SELECT coalesce(string_agg(format('#%s %s · %s · %s',
                 ejecucion_id, servicio_codigo, to_char(inicio,'DD/MM HH24:MI'),
                 left(coalesce(error,''),60)), E'\n'), 'sin fallas en 24h')
        INTO v FROM v_ejecuciones_fallidas;
        RETURN '🔧 *Fallas (24h)*' || E'\n' || v;

    ELSIF p_cmd = '/consumo' THEN
        SELECT coalesce(string_agg(format('%s: %s tokens, $%s, %s ejec.',
                 nombre, tokens_mes, round(costo_mes,2), ejecuciones_mes), E'\n'), 'sin consumo')
        INTO v FROM v_consumo_negocio;
        RETURN '💰 *Consumo del mes*' || E'\n' || v;

    -- >>> 057: el porcentaje de aliases no dice cuánta plata queda afuera.
    -- Ahora dice las dos cosas, y el dinero va primero porque es el que decide
    -- si hay que hacer algo.
    ELSIF p_cmd = '/matching' THEN
        SELECT coalesce(string_agg(format(
                 'negocio %s: $%s fuera de los cálculos (%s%% del movimiento, %s movs) · aliases %s%% resuelto, %s pendientes',
                 negocio_id, miles(dinero_sin_producto), coalesce(pct_dinero_fuera, 0),
                 movs_sin_producto, coalesce(pct_resuelto, 0), pendientes), E'\n'), 'sin datos')
        INTO v FROM v_calidad_matching;
        RETURN '🔗 *Calidad de matching*' || E'\n' || v
               || E'\n\nPara resolverlos: /pendientes, o la pestaña Ventas del /portal.';

    -- >>> 057: la salida que `match_confirmar_alias` no tenía (C3). Solo lista:
    -- confirmar necesita elegir entre productos, y eso se hace en el portal.
    ELSIF p_cmd = '/pendientes' THEN
        SELECT coalesce(string_agg(format('negocio %s · %s%s  [%s movs, $%s]',
                 c.negocio_id, e.texto,
                 CASE WHEN e.candidato_nombre IS NULL THEN ''
                      ELSE format(' → ¿%s? (%s)', e.candidato_nombre, e.similitud) END,
                 e.movimientos, miles(e.dinero)), E'\n'), 'nada pendiente')
        INTO v
        FROM v_calidad_matching c,
             LATERAL jsonb_to_recordset(alias_pendientes(c.negocio_id, 10))
               AS e(texto text, movimientos bigint, dinero numeric,
                    candidato_nombre text, similitud numeric)
        WHERE c.pendientes > 0;
        RETURN '🧩 *Productos sin resolver*' || E'\n' || coalesce(v, 'nada pendiente')
               || E'\n\nSe confirman en la pestaña Ventas del /portal.';

    ELSE
        RETURN '📋 Comandos: /salud /embudo /fallas /consumo /matching /pendientes';
    END IF;
END;
$function$
