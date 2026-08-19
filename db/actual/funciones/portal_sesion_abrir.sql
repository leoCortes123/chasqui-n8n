CREATE OR REPLACE FUNCTION public.portal_sesion_abrir(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_horas    int := 12;
    v_secreto  text := current_setting('app.settings.jwt_secret', true);
    v_usuario  bigint;
    v_negocio  bigint;
    v_exp      bigint;
BEGIN
    IF coalesce(v_secreto, '') = '' THEN
        RAISE EXCEPTION 'portal sin secreto de firma configurado';
    END IF;

    UPDATE portal_tokens SET usado_en = now()
    WHERE hash = digest(coalesce(p_token, ''), 'sha256')
      AND usado_en IS NULL
      AND expira_en > now()
    RETURNING usuario_id INTO v_usuario;

    IF v_usuario IS NULL THEN
        -- Un solo mensaje para "no existe", "ya se usó" y "venció": no hay nada
        -- que ganar contándole al que prueba tokens cuál de las tres fue.
        RETURN jsonb_build_object('ok', false, 'error', 'enlace_invalido');
    END IF;

    SELECT negocio_id INTO v_negocio FROM usuarios WHERE id = v_usuario;
    v_exp := extract(epoch FROM now() + make_interval(hours => v_horas))::bigint;

    RETURN jsonb_build_object(
        'ok', true,
        'expira', v_exp,
        'jwt', jwt_firmar(jsonb_build_object(
                 'role', 'portal_usuario',
                 'usuario_id', v_usuario,
                 'negocio_id', v_negocio,
                 'exp', v_exp), v_secreto));
END;
$function$
