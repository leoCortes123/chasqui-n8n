-- 075_panel_unico_y_descartes_sin_alerta.sql — dos cosas que la segunda prueba
-- de usuario dejó a la vista en la sesión 40 (101 archivos, 2026-08-19):
--
-- 1. Cuatro paneles en vez de uno. INGESTA-002 dice que la carga entera se
--    cuenta en UN mensaje que se edita en su lugar. Lo que pasó:
--
--      Los seis primeros archivos entraron en 0,76 s (11:03:38.62 → 11:03:39.38).
--      Cada ejecución de wf_ingesta espera 11 s y recién ahí llama a
--      `carga_evaluar`, que compara contra `carga_silencio_segundos` = 10. Como
--      las seis esperas vencen dentro de la misma ventana de 0,76 s, las seis
--      ven el mismo silencio y las seis devuelven accion='panel'.
--
--      `panel_mensaje_id` sólo se escribe DESPUÉS de que Telegram contesta
--      (gen_wf_enviar.py, nodo PanelGuardar). Mientras tanto sigue en NULL, así
--      que todas esas ejecuciones toman la rama "crear" y crean un mensaje cada
--      una. La aritmética da hasta cinco; el usuario vio cuatro.
--
--    La corrección va en la base y no en el workflow: el que decide si hay panel
--    es `carga_evaluar`, y es ahí donde falta la serialización. Se toma un
--    advisory lock por sesión y se anota `panel_pedido_en` al devolver 'panel';
--    mientras haya un panel en vuelo —pedido y todavía sin message_id— el resto
--    devuelve 'nada'. Si el envío se pierde, a los
--    `carga_panel_en_vuelo_segundos` se vuelve a intentar: la marca no puede
--    dejar a una sesión sin panel para siempre.
--
-- 2. "⚠️ 5 no los pude leer: cierre_caja_2026-03.csv, …". No es cierto: esos
--    archivos se leyeron perfectamente y se descartaron a propósito, porque su
--    formato es agregado (`mapeo->>'agregado'`) y sumarlos contaría dos veces lo
--    que ya traen los archivos de detalle. `ingesta_cargar_tabular` los marcaba
--    con `ingesta_marcar_error`, y para `carga_resumen` un descarte deliberado
--    quedaba indistinguible de un archivo ilegible.
--
--    `estado_doc` gana un cuarto valor, 'descartado': el archivo se entendió y
--    la decisión de no cargarlo es del sistema, no una falla suya. El panel no
--    avisa nada por ellos —no hay nada que el usuario deba hacer— y
--    `v_salud_ingesta` deja de contarlos como error, que era lo que ensuciaba el
--    porcentaje por formato.
--
-- El enum se reconstruye en vez de usar ALTER TYPE ... ADD VALUE porque
-- bin/migrar.sh corre cada migración en UNA transacción, y un valor agregado con
-- ADD VALUE no se puede usar hasta el commit: el UPDATE de reclasificación del
-- final fallaría con "unsafe use of new value of enum type".
--
-- Alternativas descartadas:
--
--   - Bajar `carga_silencio_segundos` o subir la espera de wf_ingesta: mueve la
--     ventana de carrera, no la cierra. Con archivos entrando en ráfaga siempre
--     hay un instante en el que N ejecuciones ven el mismo silencio.
--   - Que el workflow chequee `panel_mensaje_id` antes de crear: es el mismo
--     chequeo sin lock, corriendo N veces en paralelo. Y pone en n8n una
--     decisión que ya vive en `carga_evaluar`.
--   - Filtrar el aviso por el texto del error: frágil, y deja el estado
--     mintiendo igual para todo lo que lea `documentos`.

-- ── 1. estado_doc gana 'descartado' ──────────────────────────────────────────
DROP VIEW IF EXISTS public.v_salud_ingesta;

ALTER TYPE public.estado_doc RENAME TO estado_doc_v0;
CREATE TYPE public.estado_doc AS ENUM ('pendiente', 'parseado', 'error', 'descartado');

ALTER TABLE public.documentos
  ALTER COLUMN estado DROP DEFAULT,
  ALTER COLUMN estado TYPE public.estado_doc USING estado::text::public.estado_doc,
  ALTER COLUMN estado SET DEFAULT 'pendiente'::public.estado_doc;

DROP TYPE public.estado_doc_v0;

-- El porcentaje mide fallas de lectura por formato: un descarte deliberado no es
-- una falla y no puede inflarlo. Sigue apareciendo como fila, con su estado.
CREATE VIEW public.v_salud_ingesta AS
 WITH por_estado AS (
         SELECT documentos.negocio_id,
            documentos.formato_codigo,
            documentos.estado,
            count(*) AS documentos
           FROM documentos
          GROUP BY documentos.negocio_id, documentos.formato_codigo, documentos.estado
        )
 SELECT negocio_id,
    formato_codigo,
    estado,
    documentos,
    round(100.0 * sum(documentos) FILTER (WHERE estado = 'error'::estado_doc) OVER (PARTITION BY negocio_id, formato_codigo) / NULLIF(sum(documentos) OVER (PARTITION BY negocio_id, formato_codigo), 0::numeric), 1) AS pct_error_formato
   FROM por_estado
  ORDER BY negocio_id, formato_codigo, estado;

-- Espejo de `ingesta_marcar_error`, con la diferencia que importa: el motivo
-- explica una decisión del sistema, no un problema del archivo.
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
$function$;

CREATE OR REPLACE FUNCTION public.ingesta_cargar_tabular(p_documento_id bigint, p_filas jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_mapeo jsonb;
BEGIN
    SELECT f.mapeo INTO v_mapeo
    FROM documentos d JOIN formatos_documento f ON f.codigo = d.formato_codigo
    WHERE d.id = p_documento_id;

    -- Descartado, no fallado: el archivo se entendió. Cargarlo contaría dos
    -- veces lo que ya traen los detalles, así que la decisión de dejarlo afuera
    -- es del sistema y el usuario no tiene nada que hacer al respecto.
    IF coalesce((v_mapeo ->> 'agregado')::boolean, false) THEN
        RETURN ingesta_marcar_descartado(p_documento_id,
                 'es un resumen (totales por día, sin producto ni cantidad), '
                 'no un detalle de movimientos: sumarlo contaría dos veces lo '
                 'que ya traen los archivos de detalle')
               || jsonb_build_object('agregado', true);
    END IF;

    RETURN ingesta_cargar_tabular_detalle(p_documento_id, p_filas);
END;
$function$;

-- `descartados` viaja aparte de `fallados`: el panel no lo usa para avisar nada,
-- pero quien mire el resumen tiene que poder ver que hubo archivos que quedaron
-- fuera del análisis y por qué.
CREATE OR REPLACE FUNCTION public.carga_resumen(p_sesion_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    WITH d AS (
        SELECT * FROM documentos WHERE sesion_id = p_sesion_id
    ),
    m AS (
        SELECT count(*) AS filas, min(fecha) AS desde, max(fecha) AS hasta
        FROM movimientos WHERE documento_id IN (SELECT id FROM d)
    ),
    f AS (
        SELECT coalesce(s.contexto -> 'descargas_fallidas', '[]'::jsonb) AS j
        FROM sesiones s WHERE s.id = p_sesion_id
    )
    SELECT jsonb_build_object(
        'no_bajados',  (SELECT jsonb_array_length(j) FROM f),
        'nombres_no_bajados',
                       (SELECT coalesce(string_agg(DISTINCT x, ', '), '')
                          FROM f, jsonb_array_elements_text(f.j) AS x),
        'archivos',   (SELECT count(*) FROM d WHERE estado = 'parseado'),
        'pendientes', (SELECT count(*) FROM d WHERE estado = 'pendiente'),
        'fallados',   (SELECT count(*) FROM d WHERE estado = 'error'),
        'descartados',(SELECT count(*) FROM d WHERE estado = 'descartado'),
        'nombres_descartados',
                      (SELECT coalesce(string_agg(nombre_archivo, ', '
                                                  ORDER BY id), '')
                         FROM (SELECT id, nombre_archivo FROM d
                                WHERE estado = 'descartado' ORDER BY id LIMIT 5) t),
        'nombres_fallados',
                      (SELECT coalesce(string_agg(nombre_archivo, ', '
                                                  ORDER BY id), '')
                         FROM (SELECT id, nombre_archivo FROM d
                                WHERE estado = 'error' ORDER BY id LIMIT 5) t),
        'movimientos', (SELECT filas FROM m),
        'desde',       (SELECT desde  FROM m),
        'hasta',       (SELECT hasta  FROM m),
        'periodo',     (SELECT coalesce(periodo_es(desde, hasta), '') FROM m),
        'ultimo_en',   (SELECT max(creado_en) FROM d)
    );
$function$;

-- ── 2. Un solo panel ─────────────────────────────────────────────────────────
ALTER TABLE public.sesiones ADD COLUMN IF NOT EXISTS panel_pedido_en timestamptz;

COMMENT ON COLUMN public.sesiones.panel_pedido_en IS
  'Cuándo carga_evaluar mandó pedir un panel. Mientras panel_mensaje_id sea NULL '
  'y esta marca sea reciente, hay un panel en vuelo y nadie más pide otro.';

-- Cuánto se espera el message_id de un panel recién pedido antes de dar el
-- envío por perdido y permitir que se pida otro.
INSERT INTO public.parametros (negocio_id, clave, valor)
VALUES (NULL, 'carga_panel_en_vuelo_segundos', '30')
ON CONFLICT (clave) WHERE negocio_id IS NULL DO NOTHING;

CREATE OR REPLACE FUNCTION public.carga_evaluar(p_sesion_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_ses      record;
    v_res      jsonb;
    v_silencio int := coalesce(
        (parametro(NULL, 'carga_silencio_segundos'))::text::int, 10);
    v_vuelo    int := coalesce(
        (parametro(NULL, 'carga_panel_en_vuelo_segundos'))::text::int, 30);
    v_ultimo   timestamptz;
    v_ejec_id  bigint;
BEGIN
    -- Todo lo que sigue decide si sale un mensaje al chat, y con una ráfaga de
    -- archivos hay N ejecuciones acá adentro al mismo tiempo. El lock las
    -- ordena; sin él las N leen el mismo estado y las N mandan panel.
    PERFORM pg_advisory_xact_lock(hashtext('carga_panel')::bigint, p_sesion_id);

    -- La sesión se lee DESPUÉS del lock: leerla antes es volver a mirar un
    -- estado que la ejecución de al lado está por cambiar.
    SELECT * INTO v_ses FROM sesiones WHERE id = p_sesion_id;
    IF v_ses.id IS NULL OR v_ses.cerrada_en IS NOT NULL THEN
        RETURN jsonb_build_object('accion', 'nada');
    END IF;

    v_res    := carga_resumen(p_sesion_id);
    v_ultimo := (v_res ->> 'ultimo_en')::timestamptz;

    -- Todavía están llegando: el que entre después se encarga.
    IF v_ultimo IS NOT NULL AND now() - v_ultimo < make_interval(secs => v_silencio) THEN
        RETURN jsonb_build_object('accion', 'nada');
    END IF;

    -- Panel en vuelo: alguien ya lo pidió y Telegram todavía no devolvió el
    -- message_id con el que se edita. Pedir otro es crear un mensaje más.
    IF v_ses.panel_mensaje_id IS NULL
       AND v_ses.panel_pedido_en IS NOT NULL
       AND now() - v_ses.panel_pedido_en < make_interval(secs => v_vuelo) THEN
        RETURN jsonb_build_object('accion', 'nada');
    END IF;

    -- Silencio, y el botón ya estaba tocado.
    IF v_ses.analisis_pedido_en IS NOT NULL AND v_ses.estado = 'recibiendo' THEN
        IF NOT carga_hay_con_que(p_sesion_id) THEN
            UPDATE sesiones SET panel_pedido_en = now() WHERE id = p_sesion_id;
            RETURN jsonb_build_object('accion', 'panel',
                     'panel', carga_panel(p_sesion_id, 'panel'));
        END IF;
        v_ejec_id := carga_arrancar(p_sesion_id);
        IF v_ejec_id IS NULL THEN               -- otro llegó primero
            RETURN jsonb_build_object('accion', 'nada');
        END IF;
        UPDATE sesiones SET panel_pedido_en = now() WHERE id = p_sesion_id;
        RETURN jsonb_build_object('accion', 'analizar', 'ejecucion_id', v_ejec_id,
                 'panel', carga_panel(p_sesion_id, 'analizando'));
    END IF;

    -- Silencio y nadie pidió nada: solo refresco el contador.
    IF v_ses.estado = 'recibiendo' THEN
        UPDATE sesiones SET panel_pedido_en = now() WHERE id = p_sesion_id;
        RETURN jsonb_build_object('accion', 'panel',
                 'panel', carga_panel(p_sesion_id, 'panel'));
    END IF;

    RETURN jsonb_build_object('accion', 'nada');
END;
$function$;

-- ── 3. Lo ya cargado ─────────────────────────────────────────────────────────
-- Los documentos que están en 'error' por ser de un formato agregado nunca
-- fueron un error: se reclasifican. El filtro es el formato, no el texto.
UPDATE public.documentos d
   SET estado = 'descartado'
  FROM public.formatos_documento f
 WHERE f.codigo = d.formato_codigo
   AND d.estado = 'error'
   AND coalesce((f.mapeo ->> 'agregado')::boolean, false);
