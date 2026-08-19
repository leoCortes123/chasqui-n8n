CREATE OR REPLACE FUNCTION public.informe_salud_bloque(p_salud jsonb, p_servicio text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_lineas text[] := '{}';
    v_tmp    text;
    v_clave  text;
    v_eti    text;
    v_val    numeric;
BEGIN
    IF p_salud IS NULL OR jsonb_typeof(p_salud) <> 'object'
       OR p_salud -> 'indice' IS NULL THEN
        RETURN NULL;
    END IF;

    v_tmp := plantilla_cuerpo_srv('informe.salud_linea', p_servicio,
               '{{semaforo}} {{etiqueta}} <code>{{barra}}</code> {{valor}}');

    FOR v_clave, v_eti IN
        SELECT * FROM (VALUES ('ventas','Ventas    '), ('margenes','Márgenes  '),
                              ('inventario','Inventario'), ('compras','Compras   '),
                              ('riesgos','Riesgos   ')) AS t(c, e)
    LOOP
        CONTINUE WHEN p_salud -> v_clave IS NULL;
        v_val := (p_salud ->> v_clave)::numeric;
        -- >>> 054: la nota de inventario calculada sobre stock sin conteo
        -- lleva una marca. No se oculta la nota —sería peor— pero tampoco
        -- se presenta como si el stock fuera un dato conocido.
        v_lineas := v_lineas || replace(replace(replace(replace(v_tmp,
            '{{semaforo}}', semaforo(v_val)),
            '{{etiqueta}}', esc_html(v_eti)),
            '{{barra}}',    barra_10(v_val)),
            '{{valor}}',    lpad(v_val::int::text, 3, ' ')
              || CASE WHEN v_clave = 'inventario'
                       AND (p_salud ->> 'inventario_estimado')::boolean
                      THEN ' *' ELSE '' END);
    END LOOP;

    IF cardinality(v_lineas) = 0 THEN
        RETURN NULL;
    END IF;

    -- La nota al pie solo aparece si hubo algo que marcar.
    IF coalesce((p_salud ->> 'inventario_estimado')::boolean, false)
       AND p_salud -> 'inventario' IS NOT NULL THEN
        -- array_append y no `||`: con un literal sin tipo, `text[] || '...'`
        -- resuelve a array_cat e intenta leer la frase como un array.
        v_lineas := array_append(v_lineas,
            E'\n<i>* Inventario estimado: es lo que compraste menos lo que vendiste. Pasame un conteo y la nota se calcula sobre tu stock real.</i>');
    END IF;

    RETURN replace(replace(
        plantilla_cuerpo_srv('informe.salud', p_servicio,
            E'🩺 <b>Salud del negocio</b>\n{{lineas}}\n\n<b>Índice general: {{indice}}/100</b>'),
        '{{lineas}}', array_to_string(v_lineas, E'\n')),
        '{{indice}}', (p_salud ->> 'indice'));
END;
$function$
