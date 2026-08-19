CREATE OR REPLACE FUNCTION public.resolver_plantilla(p_clave text, p_vars jsonb DEFAULT '{}'::jsonb, p_teclado jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_cuerpo  text;
    v_formato text;
    v_crudas  jsonb;
    v_teclado jsonb;
    v_vars    jsonb;
    k text; val text;
BEGIN
    v_vars := CASE WHEN jsonb_typeof(p_vars) = 'object' THEN p_vars ELSE '{}'::jsonb END;

    SELECT cuerpo, formato, crudas, teclado
      INTO v_cuerpo, v_formato, v_crudas, v_teclado
    FROM plantillas WHERE clave = p_clave AND activo LIMIT 1;

    IF v_cuerpo IS NULL THEN
        -- Sin plantilla se manda la clave como texto. Eso es contenido
        -- arbitrario (así entregan su salida los comandos de admin), así que
        -- acá SÍ se escapa.
        v_cuerpo  := esc_html(p_clave);
        v_formato := 'html';
        v_crudas  := '[]'::jsonb;
        v_teclado := '[]'::jsonb;
    END IF;

    FOR k, val IN SELECT * FROM jsonb_each_text(v_vars) LOOP
        v_cuerpo := replace(v_cuerpo, '{{' || k || '}}',
            CASE WHEN v_crudas ? k THEN coalesce(val, '') ELSE esc_html(val) END);
    END LOOP;

    RETURN jsonb_build_object('texto', v_cuerpo, 'formato', v_formato,
             'teclado', teclado_markup(
                 CASE WHEN jsonb_typeof(coalesce(p_teclado, 'null'::jsonb)) = 'array'
                      THEN p_teclado ELSE v_teclado END, v_vars));
END;
$function$
