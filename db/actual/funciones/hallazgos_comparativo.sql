CREATE OR REPLACE FUNCTION public.hallazgos_comparativo(p_negocio_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_ant jsonb := snapshot_anterior(p_negocio_id);
    v_sal jsonb;
BEGIN
    IF v_ant IS NULL THEN RETURN NULL; END IF;
    v_sal := salud_negocio(p_negocio_id);

    RETURN jsonb_strip_nulls(jsonb_build_object(
      'fecha_anterior',  v_ant ->> 'fecha',
      'parcial',         coalesce((v_ant #> '{metricas,parcial}')::boolean, false),
      'salud_anterior',  v_ant #> '{salud,indice}',
      'salud_actual',    v_sal -> 'indice',
      -- El delta viene calculado desde SQL. Si se lo dejáramos al modelo,
      -- estaríamos moviéndole una resta, y `validar_cifras` rechazaría el
      -- resultado por no estar en los hallazgos (R-I).
      'salud_delta',     CASE WHEN v_ant #> '{salud,indice}' IS NOT NULL
                               AND v_sal -> 'indice' IS NOT NULL
                              THEN to_jsonb((v_sal ->> 'indice')::numeric
                                            - (v_ant #>> '{salud,indice}')::numeric) END,
      'ventas_anterior',  v_ant #> '{metricas,totales,ventas}',
      'compras_anterior', v_ant #> '{metricas,totales,compras}'));
END;
$function$
