CREATE OR REPLACE FUNCTION public.carga_panel(p_sesion_id bigint, p_modo text DEFAULT 'panel'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_ses     record;
    v_res     jsonb := carga_resumen(p_sesion_id);
    v_clave   text;
    v_detalle text := '';
    v_avisos  text := '';
    v_n       int  := coalesce((v_res ->> 'archivos')::int, 0);
    v_mov     bigint := coalesce((v_res ->> 'movimientos')::bigint, 0);
    v_plant   record;
BEGIN
    -- El chat sale de `identidades` primero y de `usuarios` después: un usuario
    -- que entró por WhatsApp (044) no tiene telegram_chat_id, y uno de Telegram
    -- puede no tener identidad si viene de antes de la 044.
    SELECT s.*,
           coalesce(
             (SELECT (i.datos ->> 'chat_id')::bigint FROM identidades i
               WHERE i.usuario_id = s.usuario_id AND i.datos ? 'chat_id'
               ORDER BY i.vista_en DESC LIMIT 1),
             u.telegram_chat_id) AS chat_id
      INTO v_ses
    FROM sesiones s
    JOIN usuarios u ON u.id = s.usuario_id
    WHERE s.id = p_sesion_id;
    IF v_ses.id IS NULL OR v_ses.chat_id IS NULL THEN RETURN NULL; END IF;

    v_clave := CASE p_modo
                 WHEN 'esperando'  THEN 'carga.panel_esperando'
                 WHEN 'analizando' THEN 'carga.panel_analizando'
                 ELSE 'carga.panel' END;

    -- Detalle: solo lo que hay. Una línea "0 registros" en el primer archivo que
    -- todavía se está parseando asusta sin motivo.
    IF v_mov > 0 THEN
        v_detalle := format(E'\n📊 <b>%s</b> registros', miles(v_mov));
        IF coalesce(v_res ->> 'periodo', '') <> '' THEN
            v_detalle := v_detalle || format(E'\n📅 %s', v_res ->> 'periodo');
        END IF;
        v_detalle := v_detalle || E'\n';
    END IF;

    -- Avisos: los archivos que no se pudieron leer y los que quedaron guardados
    -- sin cargar. Van acá y no como mensaje aparte —que es lo que hacían hasta
    -- ahora— justamente para no volver a inundar el chat.
    IF coalesce((v_res ->> 'fallados')::int, 0) > 0 THEN
        v_avisos := v_avisos || format(E'\n⚠️ %s no los pude leer: %s',
                      (v_res ->> 'fallados'), (v_res ->> 'nombres_fallados'));
    END IF;
    IF coalesce((v_res ->> 'pendientes')::int, 0) > 0 THEN
        v_avisos := v_avisos || format(
          E'\n💾 %s guardados sin analizar todavía. No los perdés.',
          (v_res ->> 'pendientes'));
    END IF;
    -- El único caso en el que hay que pedir un reenvío, así que se pide claro y
    -- con el nombre: un archivo que no se pudo bajar no dejó ni rastro que
    -- recuperar después.
    IF coalesce((v_res ->> 'no_bajados')::int, 0) > 0 THEN
        v_avisos := v_avisos || format(
          E'\n❌ %s no los pude bajar del chat: %s\n   Volvé a mandar solo esos.',
          (v_res ->> 'no_bajados'), (v_res ->> 'nombres_no_bajados'));
    END IF;
    IF v_avisos <> '' THEN v_avisos := v_avisos || E'\n'; END IF;

    SELECT * INTO v_plant FROM resolver_plantilla(v_clave,
        jsonb_build_object(
          'archivos',        v_n::text,
          'palabra_archivo', CASE WHEN v_n = 1 THEN 'archivo' ELSE 'archivos' END,
          'detalle',         v_detalle,
          'avisos',          v_avisos),
        NULL) AS t(res);

    -- `canal` viaja para que el workflow sepa que en WhatsApp no puede editar ni
    -- fijar: allá el panel degrada a un mensaje más (mismo criterio que la 070).
    RETURN jsonb_build_object(
        'sesion_id',  p_sesion_id,
        'chat_id',    v_ses.chat_id,
        'canal',      canal_de_chat(v_ses.chat_id),
        'mensaje_id', v_ses.panel_mensaje_id,
        'modo',       p_modo,
        'texto',      v_plant.res ->> 'texto',
        'teclado',    v_plant.res -> 'teclado',
        'resumen',    v_res);
END;
$function$
