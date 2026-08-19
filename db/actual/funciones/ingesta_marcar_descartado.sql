CREATE OR REPLACE FUNCTION public.ingesta_marcar_descartado(p_documento_id bigint, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
BEGIN
    UPDATE documentos SET estado = 'descartado', error = p_motivo
     WHERE id = p_documento_id;
    RETURN jsonb_build_object('documento_id', p_documento_id,
                              'estado', 'descartado', 'motivo', p_motivo);
END;
$function$
