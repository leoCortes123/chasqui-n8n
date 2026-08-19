-- 023_teclados.sql — los botones también son filas, no nodos.
--
-- Objetivo: que el usuario escriba lo mínimo. Cada mensaje del bot puede llevar
-- su propio teclado inline, y ese teclado se define en la MISMA fila que el
-- texto. Agregar un botón es un UPDATE, igual que cambiar una palabra.
--
-- Forma abstracta (columna plantillas.teclado), no la de Telegram:
--
--   [[{"texto":"🚀 Empezar","dato":"/nueva"}],
--    [{"texto":"❓ Cómo funciona","dato":"/comofunciona"}]]
--
--   filas -> botones. `dato` viaja como callback_data; `url` abre un enlace.
--   Tanto `texto` como `dato` admiten {{variables}}, para teclados con
--   contenido dinámico (la lista de servicios, por ejemplo).
--
-- teclado_markup la traduce a lo que espera la API (`inline_keyboard`), así que
-- n8n no arma nada: recibe el reply_markup listo y lo pasa. Un teclado vacío
-- devuelve {"inline_keyboard": []}, que Telegram acepta y muestra sin botones
-- —a propósito, para no tener que mandar NULL y arriesgar un 400 en el envío.

-- === Escape HTML, ahora reutilizable ========================================
-- Estaba embutido tres veces dentro de resolver_plantilla (migración 022).
CREATE FUNCTION esc_html(p_texto text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT replace(replace(replace(coalesce(p_texto, ''),
             '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
$$;

-- === Columnas nuevas ========================================================
-- `crudas`: nombres de variables que se insertan SIN escapar porque su valor ya
-- es HTML que generamos nosotros (el informe renderizado). Todo lo demás se
-- sigue escapando: la regla de 022 no se relaja, se hace explícita y auditable
-- —se puede listar de un SELECT qué plantilla confía en qué variable—.
ALTER TABLE plantillas
    ADD COLUMN IF NOT EXISTS teclado jsonb NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN IF NOT EXISTS crudas  jsonb NOT NULL DEFAULT '[]'::jsonb;

-- === teclado_markup =========================================================
CREATE FUNCTION teclado_markup(p_teclado jsonb, p_vars jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_vacio jsonb := jsonb_build_object('inline_keyboard', '[]'::jsonb);
    v_filas jsonb := '[]'::jsonb;
    v_btns  jsonb;
    v_fila  jsonb;
    v_b     jsonb;
    v_vars  jsonb;
    v_texto text;
    v_dato  text;
    k text; val text;
BEGIN
    IF p_teclado IS NULL OR jsonb_typeof(p_teclado) <> 'array' THEN
        RETURN v_vacio;
    END IF;
    v_vars := CASE WHEN jsonb_typeof(p_vars) = 'object' THEN p_vars ELSE '{}'::jsonb END;

    FOR v_fila IN SELECT * FROM jsonb_array_elements(p_teclado) LOOP
        CONTINUE WHEN jsonb_typeof(v_fila) <> 'array';
        v_btns := '[]'::jsonb;

        FOR v_b IN SELECT * FROM jsonb_array_elements(v_fila) LOOP
            CONTINUE WHEN jsonb_typeof(v_b) <> 'object';
            v_texto := v_b ->> 'texto';
            v_dato  := v_b ->> 'dato';
            CONTINUE WHEN v_texto IS NULL;

            FOR k, val IN SELECT * FROM jsonb_each_text(v_vars) LOOP
                v_texto := replace(v_texto, '{{' || k || '}}', coalesce(val, ''));
                IF v_dato IS NOT NULL THEN
                    v_dato := replace(v_dato, '{{' || k || '}}', coalesce(val, ''));
                END IF;
            END LOOP;

            -- La etiqueta NO se escapa: Telegram la muestra literal, sin parser
            -- de entidades. Escaparla haría aparecer "&amp;" en el botón.
            IF v_b ? 'url' THEN
                v_btns := v_btns || jsonb_build_array(
                    jsonb_build_object('text', v_texto, 'url', v_b ->> 'url'));
            ELSIF coalesce(v_dato, '') <> '' THEN
                -- callback_data: 1..64 bytes. Se recorta en vez de reventar; un
                -- botón que no responde se ve, un 400 se lleva todo el mensaje.
                v_btns := v_btns || jsonb_build_array(
                    jsonb_build_object('text', v_texto, 'callback_data', left(v_dato, 64)));
            END IF;
        END LOOP;

        IF jsonb_array_length(v_btns) > 0 THEN
            v_filas := v_filas || jsonb_build_array(v_btns);
        END IF;
    END LOOP;

    IF jsonb_array_length(v_filas) = 0 THEN RETURN v_vacio; END IF;
    RETURN jsonb_build_object('inline_keyboard', v_filas);
END;
$$;

-- === teclado_servicios ======================================================
-- Un servicio activo = un botón. Agregar un servicio sigue siendo un INSERT y
-- ahora también aparece solo en el menú.
CREATE FUNCTION teclado_servicios() RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT coalesce(jsonb_agg(jsonb_build_array(
             jsonb_build_object('texto', nombre, 'dato', 'svc:' || codigo))
             ORDER BY orden), '[]'::jsonb)
           || jsonb_build_array(jsonb_build_array(
             jsonb_build_object('texto', '✖️ Cancelar', 'dato', '/cancelar')))
    FROM servicios WHERE activo;
$$;

-- === resolver_plantilla (v3: devuelve también el teclado) ====================
-- Se DROPea antes de crear: agregar un parámetro con DEFAULT no reemplaza la
-- función, crea una sobrecarga, y entonces la llamada de dos argumentos que hace
-- wf_enviar quedaría ambigua ("function is not unique").
DROP FUNCTION IF EXISTS resolver_plantilla(text, jsonb);

CREATE FUNCTION resolver_plantilla(p_clave text,
                                   p_vars jsonb DEFAULT '{}'::jsonb,
                                   p_teclado jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
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
        -- Degradación: sin plantilla se manda la clave como texto. Eso es
        -- contenido arbitrario (así entregan su salida los comandos de admin),
        -- así que acá SÍ se escapa.
        v_cuerpo  := esc_html(p_clave);
        v_formato := 'html';
        v_crudas  := '[]'::jsonb;
        v_teclado := '[]'::jsonb;
    END IF;

    FOR k, val IN SELECT * FROM jsonb_each_text(v_vars) LOOP
        v_cuerpo := replace(v_cuerpo, '{{' || k || '}}',
            CASE WHEN v_crudas ? k THEN coalesce(val, '') ELSE esc_html(val) END);
    END LOOP;

    -- El teclado que venga por parámetro pisa el de la fila: así el router puede
    -- inyectar uno dinámico (la lista de servicios) sin duplicar la plantilla.
    -- Solo lo pisa si es un array de verdad: wf_enviar manda 'null'::jsonb
    -- cuando la respuesta no trae teclado propio, y eso NO debe borrar el de la
    -- fila. Por eso no alcanza un coalesce, que solo ve el NULL de SQL.
    RETURN jsonb_build_object('texto', v_cuerpo, 'formato', v_formato,
             'teclado', teclado_markup(
                 CASE WHEN jsonb_typeof(coalesce(p_teclado, 'null'::jsonb)) = 'array'
                      THEN p_teclado ELSE v_teclado END, v_vars));
END;
$$;

-- === Teclados de cada paso ==================================================
-- Regla de diseño: todo mensaje que espere una decisión del usuario ofrece esa
-- decisión como botón. Los `dato` son los MISMOS comandos que se pueden escribir
-- a mano, así que botón y texto entran por el mismo camino en el router: no hay
-- dos máquinas de estados que mantener sincronizadas.

UPDATE plantillas SET cuerpo =
'Hola 👋 Soy <b>Chasqui</b>.

Leo los archivos de ventas y compras de tu negocio y te digo en qué estás perdiendo plata: qué productos dejan poco margen, a cuáles les subió el costo y cuáles se te van a agotar.

Tocá el botón y arrancamos.',
  teclado = '[[{"texto":"🚀 Empezar análisis","dato":"/nueva"}],
              [{"texto":"❓ Cómo funciona","dato":"/comofunciona"}]]'::jsonb,
  version = version + 1
WHERE clave = 'sistema.bienvenida';

UPDATE plantillas SET cuerpo =
'Antes de seguir necesito tu permiso para tratar los datos de tu negocio.',
  teclado = '[[{"texto":"✅ Acepto","dato":"acepto"}],
              [{"texto":"🔒 Qué datos uso","dato":"/privacidad"}]]'::jsonb,
  version = version + 1
WHERE clave = 'sistema.no_autorizado';

-- El texto deja de pedir que escriban el nombre: ahora se toca.
UPDATE plantillas SET cuerpo = '¿Qué análisis necesitás?',
  variables = '[]'::jsonb,
  version = version + 1
WHERE clave = 'sistema.elegir_servicio';

UPDATE plantillas SET cuerpo =
'Listo: <b>{{servicio}}</b>.

Mandame lo que tengas: las facturas XML de la DIAN, o el archivo de ventas que exporte tu sistema (Excel, CSV, lo que sea). No importa cómo se llamen las columnas, yo me arreglo.

Cuando termines de enviar, tocá <b>Analizar</b>.',
  teclado = '[[{"texto":"📊 Analizar","dato":"/listo"}],
              [{"texto":"✖️ Cancelar","dato":"/cancelar"}]]'::jsonb,
  version = version + 1
WHERE clave = 'sistema.pedir_archivos';

UPDATE plantillas
SET teclado = '[[{"texto":"📊 Analizar","dato":"/listo"}],
                [{"texto":"✖️ Cancelar","dato":"/cancelar"}]]'::jsonb,
    version = version + 1
WHERE clave IN ('ingesta.ok', 'ingesta.formato_nuevo', 'ingesta.parcial',
                'ingesta.error_archivo', 'ingesta.pedir_columnas',
                'sistema.esperando_listo');

UPDATE plantillas
SET teclado = '[[{"texto":"🚀 Empezar análisis","dato":"/nueva"}],
                [{"texto":"❓ Cómo funciona","dato":"/comofunciona"}]]'::jsonb,
    version = version + 1
WHERE clave IN ('sistema.sin_sesion', 'sistema.no_entendido', 'sesion.recordatorio');

UPDATE plantillas
SET teclado = '[[{"texto":"✖️ Cancelar","dato":"/cancelar"}]]'::jsonb,
    version = version + 1
WHERE clave = 'sistema.sin_documentos';

UPDATE plantillas
SET teclado = '[[{"texto":"🔄 Intentar de nuevo","dato":"/nueva"}]]'::jsonb,
    version = version + 1
WHERE clave IN ('ejecucion.fallida', 'ejecucion.bloqueada_cupo');

-- Los textos que todavía hablaban de escribir comandos.
UPDATE plantillas SET cuerpo =
'No tenés ningún análisis en curso.',
  version = version + 1
WHERE clave = 'sistema.sin_sesion';

UPDATE plantillas SET cuerpo =
'No te entendí. Tocá un botón y seguimos.',
  version = version + 1
WHERE clave = 'sistema.no_entendido';

UPDATE plantillas SET cuerpo =
'Todavía no recibí ningún archivo que pueda leer. Mandame al menos uno.',
  version = version + 1
WHERE clave = 'sistema.sin_documentos';

UPDATE plantillas SET cuerpo =
'Recibido. Seguí enviando archivos, o tocá <b>Analizar</b> cuando termines.',
  version = version + 1
WHERE clave = 'sistema.esperando_listo';

UPDATE plantillas SET cuerpo = replace(cuerpo,
  E'\n\nSeguí enviando archivos o escribí <b>/listo</b> cuando termines.', ''),
  version = version + 1
WHERE clave = 'ingesta.ok';

UPDATE plantillas SET cuerpo = replace(cuerpo,
  'El resto de los archivos sigue en pie: podés enviarlo corregido o seguir con los demás.',
  'El resto de los archivos sigue en pie: mandalo corregido, seguí con los demás, o analizá con lo que ya tengo.'),
  version = version + 1
WHERE clave = 'ingesta.error_archivo';

-- === Plantillas nuevas ======================================================
INSERT INTO plantillas (clave, cuerpo, formato, variables, teclado) VALUES

('sistema.como_funciona',
'Son tres pasos:

<b>1.</b> Me mandás tus archivos de ventas y compras, como los exporte tu sistema: Excel, CSV o las facturas XML de la DIAN.
<b>2.</b> Yo leo las columnas y entiendo la estructura sola. Si el formato es nuevo, lo aprendo.
<b>3.</b> Te devuelvo acá mismo un informe con lo que hay que revisar esta semana.

Nada de plantillas ni de formatear archivos: mandá lo que ya tenés.',
 'html', '[]'::jsonb,
 '[[{"texto":"🚀 Empezar análisis","dato":"/nueva"}]]'::jsonb),

('sistema.privacidad',
'Uso solo lo que me mandás vos:

• Los archivos quedan guardados en la base de tu negocio, para poder comparar un mes contra otro.
• Al análisis solo van los <b>nombres de las columnas</b> y unas filas de muestra cuando tengo que entender un formato nuevo. Las cifras se procesan acá, no salen.
• No comparto tus datos con otros negocios ni los uso para nada más.
• Cuando quieras que borre todo, pedímelo y lo borro.',
 'html', '[]'::jsonb,
 '[[{"texto":"✅ Acepto","dato":"acepto"}]]'::jsonb),

('sesion.cancelada',
'Listo, cancelé ese análisis. Los archivos que ya me mandaste quedan guardados.',
 'html', '[]'::jsonb,
 '[[{"texto":"🚀 Empezar de nuevo","dato":"/nueva"}]]'::jsonb),

('ejecucion.ya_en_curso',
'⏳ Ya estoy trabajando en tu informe. Aguantame un momento, te aviso acá mismo.',
 'html', '[]'::jsonb, '[]'::jsonb),

('sistema.servicio_ya_elegido',
'Ese análisis ya está en curso: <b>{{servicio}}</b>. Seguí mandando archivos o tocá <b>Analizar</b>.',
 'html', '["servicio"]'::jsonb,
 '[[{"texto":"📊 Analizar","dato":"/listo"}],
   [{"texto":"✖️ Cancelar","dato":"/cancelar"}]]'::jsonb),

('sistema.archivo_sin_sesion',
'Recibí tu archivo y abrí un análisis de <b>{{servicio}}</b> con él. Si querías otra cosa, cancelá y elegimos de nuevo.',
 'html', '["servicio"]'::jsonb,
 '[[{"texto":"📊 Analizar","dato":"/listo"}],
   [{"texto":"✖️ Cancelar","dato":"/cancelar"}]]'::jsonb)

ON CONFLICT (clave) DO UPDATE
  SET cuerpo = EXCLUDED.cuerpo, formato = EXCLUDED.formato,
      variables = EXCLUDED.variables, teclado = EXCLUDED.teclado,
      activo = true, version = plantillas.version + 1;

-- El recordatorio del reaper decía "retomá" cuando la sesión ya estaba cerrada.
UPDATE plantillas SET cuerpo =
'Dejaste un análisis a medias y ya lo cerré por inactividad. Los archivos que me mandaste siguen guardados: si querés, arrancamos uno nuevo.',
  version = version + 1
WHERE clave = 'sesion.recordatorio';
