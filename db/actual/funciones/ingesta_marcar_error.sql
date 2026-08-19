CREATE OR REPLACE FUNCTION public.ingesta_marcar_error(p_documento_id bigint, p_error text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
BEGIN
    UPDATE documentos SET estado = 'error', error = p_error WHERE id = p_documento_id;
    RETURN jsonb_build_object('documento_id', p_documento_id, 'estado', 'error', 'error', p_error);
END;
$function$
