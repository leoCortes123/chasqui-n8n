CREATE OR REPLACE FUNCTION public.router_ctx(p_evento jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_usuario_id bigint;
    v_texto      text := btrim(coalesce(p_evento ->> 'texto', ''));
    v_cmd        text;
    v_arg        text;          -- resto del mensaje después del comando
    v_svc        text;          -- código que llegó por botón (svc:<codigo>)
    v_mod        text;          -- código de módulo (mod:/modayuda:)
    v_tip        text;          -- >>> 046: naturaleza del negocio (tipo:<codigo>)
    v_rec        text;          -- >>> 064: acción sobre una recomendación
    v_negocio_id bigint;
    v_autoriz    boolean;
    v_rol        rol_usuario;
    v_n_serv     int;
    v_consulta   boolean;
BEGIN
    -- El primer token y el resto. Se parte por espacio EN BLANCO, no por ' ':
    -- un "/saber" seguido de salto de línea es la forma natural de enseñarle
    -- algo largo, y con split_part(' ') el comando se comía el texto entero.
    v_cmd := lower(coalesce(substring(v_texto FROM '^\S+'), ''));
    v_arg := btrim(coalesce(substring(v_texto FROM '^\S+\s+(.*)$'), ''));
    IF v_texto LIKE 'svc:%' THEN
        v_svc := substring(v_texto FROM 5);
        v_cmd := 'svc';
    ELSIF v_texto LIKE 'mod:%' THEN
        v_mod := substring(v_texto FROM 5);
        v_cmd := 'mod';
    ELSIF v_texto LIKE 'modayuda:%' THEN
        v_mod := substring(v_texto FROM 10);
        v_cmd := 'modayuda';
    ELSIF v_texto LIKE 'tipo:%' THEN
        v_tip := substring(v_texto FROM 6);
        v_cmd := 'tipo';
    ELSIF v_texto LIKE 'rec:%' THEN
        -- >>> 064: 'rec:<accion>[:<id>]'. El resto queda entero en `rec` y lo
        -- parte el handler: acá solo se reconoce el prefijo.
        v_rec := substring(v_texto FROM 5);
        v_cmd := 'rec';
    ELSIF v_texto LIKE 'acepto:%' THEN
        -- >>> 051: 'acepto:<mensaje original>' — el consentimiento se lleva
        -- puesto el paso que lo disparó para poder retomarlo.
        v_arg := btrim(substring(v_texto FROM 8));
        v_cmd := 'acepto';
    END IF;

    -- El canal por defecto es telegram; el evento puede declarar otro (044).
    -- Acá también se crea el usuario y su negocio si es la primera vez (050).
    v_usuario_id := usuario_de_canal('telegram', p_evento);
    SELECT negocio_id, autorizacion_datos, rol
      INTO v_negocio_id, v_autoriz, v_rol
    FROM usuarios WHERE id = v_usuario_id;

    -- Solo los de archivos: los de texto no se eligen de una lista.
    SELECT count(*) INTO v_n_serv
    FROM servicios WHERE activo AND entrada = 'archivos';
    SELECT EXISTS (SELECT 1 FROM servicios WHERE activo AND entrada = 'texto'
                     AND codigo = 'consulta') INTO v_consulta;

    RETURN jsonb_build_object(
        'evento',     p_evento,
        'chat_id',    (p_evento #>> '{chat,id}')::bigint,
        'usuario_id', v_usuario_id,
        'negocio_id', v_negocio_id,
        'rol',        v_rol::text,
        'autoriz',    coalesce(v_autoriz, false),
        'texto',      v_texto,
        'cmd',        v_cmd,
        'arg',        v_arg,
        'svc',        v_svc,
        'mod',        v_mod,
        'tip',        v_tip,
        'rec',        v_rec,
        'tiene_doc',  coalesce((p_evento ->> 'tiene_documento')::boolean, false),
        'n_serv',     v_n_serv,
        'consulta',   v_consulta);
END;
$function$
