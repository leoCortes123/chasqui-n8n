CREATE OR REPLACE FUNCTION public.portal_token_crear(p_usuario_id bigint, p_minutos integer DEFAULT 15)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_token text := encode(gen_random_bytes(24), 'hex');
BEGIN
    -- Un enlace nuevo invalida los anteriores del mismo usuario: si alguien
    -- pidió dos, el viejo deja de servir.
    UPDATE portal_tokens SET usado_en = now()
    WHERE usuario_id = p_usuario_id AND usado_en IS NULL;

    INSERT INTO portal_tokens (usuario_id, hash, expira_en)
    VALUES (p_usuario_id, digest(v_token, 'sha256'),
            now() + make_interval(mins => greatest(p_minutos, 1)));

    RETURN v_token;
END;
$function$
