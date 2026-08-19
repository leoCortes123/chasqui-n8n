-- 043_mercado_compras.sql — segundo servicio de archivos: informe de compras.
--
-- "Mercado de compras": mira SOLO las compras del negocio (facturas DIAN o
-- cualquier tabular con tipo compra) y arma un informe para decidir mejor las
-- próximas compras: dónde se concentra el gasto, a qué le sube el costo, dónde
-- se pagan precios muy distintos por lo mismo, cómo pesa cada proveedor y qué
-- se compró que no rota.
--
-- Casi todo es filas: servicio + entradas + hallazgos + prompt + plantillas.
-- Los workflows no cambian. El router gana dos cosas puntuales:
--   * al elegir este servicio, si el negocio YA tiene compras cargadas se le
--     ofrece generar con eso o cargar más (verificación de existencia);
--   * /listo corre sin archivos en la sesión si hay compras previas.
-- Con dos servicios de archivos activos, /nueva pasa solo a mostrar el teclado
-- de servicios (el router ya lo hacía con v_n_serv > 1).

-- === 1. Servicio y formatos de entrada ======================================

INSERT INTO servicios (codigo, nombre, descripcion, entrada, funcion_hallazgos, orden, activo)
VALUES ('mercado_compras', 'Mercado de compras',
        'Analiza las facturas de compra y reporta gasto concentrado, costos al alza, dispersión de precios y peso de cada proveedor.',
        'archivos', 'hallazgos_compras', 15, true)
ON CONFLICT (codigo) DO UPDATE
  SET nombre = EXCLUDED.nombre, descripcion = EXCLUDED.descripcion,
      entrada = EXCLUDED.entrada, funcion_hallazgos = EXCLUDED.funcion_hallazgos,
      orden = EXCLUDED.orden, activo = true;

INSERT INTO servicios_entradas (servicio_codigo, formato_codigo, obligatorio, min_archivos, max_archivos) VALUES
  ('mercado_compras', 'dian_xml',         false, 0, NULL),
  ('mercado_compras', 'pos_csv_generico', false, 0, 12)
ON CONFLICT (servicio_codigo, formato_codigo) DO NOTHING;

-- === 2. Hallazgos ===========================================================
-- Mismo contrato que hallazgos_generar: los números van crudos, tal cual los
-- valida validar_cifras. La etiqueta de producto prefiere el nombre canónico
-- (matching) y cae al texto de la factura si aún no resolvió.

CREATE OR REPLACE FUNCTION hallazgos_compras(p_negocio_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_deriva_ali numeric := (parametro(p_negocio_id, 'deriva_costo_alerta_pct'))::text::numeric;
    v_out jsonb;
BEGIN
    WITH compras AS (
        SELECT m.*, coalesce(p.nombre_canonico, m.raw ->> 'descripcion',
                             m.raw ->> 'producto', 'sin nombre') AS etiqueta,
               nullif(btrim(coalesce(m.raw ->> 'proveedor', '')), '') AS proveedor
        FROM movimientos m
        LEFT JOIN productos p ON p.id = m.producto_id
        WHERE m.negocio_id = p_negocio_id AND m.tipo = 'compra'
    ),
    gasto AS (SELECT sum(valor_total) AS total FROM compras)
    SELECT jsonb_build_object(
      'negocio_id', p_negocio_id,
      'generado_en', now(),

      'periodo', (SELECT jsonb_build_object(
                    'desde', min(fecha), 'hasta', max(fecha),
                    'movimientos_compra', count(*))
                  FROM compras WHERE fecha IS NOT NULL),

      'resumen', (SELECT jsonb_build_object(
                    'productos',   count(DISTINCT etiqueta),
                    'gasto_total', round(coalesce(sum(valor_total), 0)),
                    'proveedores', count(DISTINCT proveedor) FILTER (WHERE proveedor IS NOT NULL),
                    'documentos',  count(DISTINCT documento_id))
                  FROM compras),

      -- Dónde se va la plata: top de gasto por producto con su participación.
      'gasto_producto', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                           'producto', etiqueta, 'gasto', gasto_p,
                           'unidades', unidades, 'pct_gasto', pct) ORDER BY gasto_p DESC), '[]')
                         FROM (SELECT etiqueta,
                                      round(sum(valor_total)) AS gasto_p,
                                      round(sum(cantidad))    AS unidades,
                                      round((sum(valor_total) * 100.0
                                             / nullif((SELECT total FROM gasto), 0))::numeric, 1) AS pct
                               FROM compras GROUP BY etiqueta
                               ORDER BY sum(valor_total) DESC NULLS LAST LIMIT 8) t),

      -- Costo al alza: misma vista y mismo umbral que el análisis de ventas.
      'deriva_costo', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                         'producto_id', d.producto_id, 'producto', p.nombre_canonico,
                         'costo_ini', d.costo_ini, 'costo_fin', d.costo_fin,
                         'deriva_pct', d.deriva_pct) ORDER BY abs(d.deriva_pct) DESC), '[]')
                       FROM v_deriva_costo d JOIN productos p ON p.id = d.producto_id
                       WHERE d.negocio_id = p_negocio_id
                         AND abs(d.deriva_pct) >= v_deriva_ali),

      -- Precios muy distintos por el mismo producto: margen para negociar.
      'precio_disperso', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                            'producto', etiqueta, 'precio_min', pmin,
                            'precio_max', pmax, 'dispersion_pct', disp)
                            ORDER BY disp DESC), '[]')
                          FROM (SELECT etiqueta,
                                       round(min(valor_unitario)) AS pmin,
                                       round(max(valor_unitario)) AS pmax,
                                       round(((max(valor_unitario) - min(valor_unitario))
                                              / nullif(min(valor_unitario), 0) * 100)::numeric, 1) AS disp
                                FROM compras WHERE valor_unitario > 0
                                GROUP BY etiqueta
                                HAVING count(*) > 1
                                   AND (max(valor_unitario) - min(valor_unitario))
                                       / nullif(min(valor_unitario), 0) >= 0.10
                                ORDER BY disp DESC LIMIT 8) t),

      -- Peso de cada proveedor en el gasto.
      'proveedores', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                        'proveedor', coalesce(proveedor, 'sin dato'),
                        'gasto', gasto_v, 'pct_gasto', pct) ORDER BY gasto_v DESC), '[]')
                      FROM (SELECT proveedor, round(sum(valor_total)) AS gasto_v,
                                   round((sum(valor_total) * 100.0
                                          / nullif((SELECT total FROM gasto), 0))::numeric, 1) AS pct
                            FROM compras GROUP BY proveedor
                            ORDER BY sum(valor_total) DESC NULLS LAST LIMIT 6) t),

      -- Comprado que no registra ni una venta: plata quieta. Solo tiene sentido
      -- si el negocio también carga ventas; si no hay ventas, va vacío y el
      -- prompt no arma la sección.
      'sin_venta', CASE WHEN EXISTS (SELECT 1 FROM movimientos
                                     WHERE negocio_id = p_negocio_id AND tipo = 'venta')
                   THEN (SELECT coalesce(jsonb_agg(jsonb_build_object(
                           'producto', etiqueta, 'unidades', unidades, 'gasto', gasto_p)
                           ORDER BY gasto_p DESC), '[]')
                         FROM (SELECT c.etiqueta, round(sum(c.cantidad)) AS unidades,
                                      round(sum(c.valor_total)) AS gasto_p
                               FROM compras c
                               WHERE c.producto_id IS NOT NULL
                                 AND NOT EXISTS (SELECT 1 FROM movimientos v
                                                 WHERE v.negocio_id = p_negocio_id
                                                   AND v.tipo = 'venta'
                                                   AND v.producto_id = c.producto_id)
                               GROUP BY c.etiqueta
                               ORDER BY sum(c.valor_total) DESC LIMIT 8) t)
                   ELSE '[]'::jsonb END
    ) INTO v_out;

    RETURN v_out;
END;
$$;

-- La sobrecarga de despacho (029): el contexto de sesión no se usa acá.
CREATE OR REPLACE FUNCTION hallazgos_compras(p_negocio_id bigint, p_contexto jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT hallazgos_compras(p_negocio_id);
$$;

-- === 3. Prompt ==============================================================
-- Mismo sistema que ventas_compras (el esquema JSON es el que entiende
-- informe_render); cambia el encargo del usuario.

UPDATE prompts SET activo = false WHERE servicio_codigo = 'mercado_compras';
INSERT INTO prompts (servicio_codigo, sistema, usuario, modelo, temperatura, max_tokens, activo)
SELECT 'mercado_compras', sistema,
'Con base EXCLUSIVAMENTE en estos hallazgos, armá el JSON del informe de COMPRAS para el dueño del negocio: la meta es que decida mejor sus próximas compras. Cubrí, en este orden y solo si hay datos: en qué productos se concentra el gasto, a qué productos les está subiendo el costo, dónde está pagando precios muy distintos por el mismo producto (ahí hay margen para negociar), cómo se reparte el gasto entre proveedores, y qué compró que no ha vendido ni una unidad (plata quieta en el estante). Las acciones deben ser decisiones de compra o de negociación concretas para esta semana.

HALLAZGOS:
{{hallazgos}}',
       modelo, temperatura, max_tokens, true
FROM prompts WHERE servicio_codigo = 'ventas_compras' AND activo
LIMIT 1;

-- === 4. Plantillas ==========================================================

INSERT INTO plantillas (clave, cuerpo, formato, variables, teclado) VALUES
  ('mercado.datos_previos',
   'Ya tengo compras tuyas cargadas: {{documentos}} documento(s), {{productos}} productos, {{gasto}} en total{{rango}}.

¿Genero el informe de mercado con eso, o cargás facturas nuevas primero?',
   'html', '["documentos","productos","gasto","rango"]',
   '[[{"dato": "/listo",    "texto": "🛒 Generar con lo que tengo"}],
     [{"dato": "/faltan",   "texto": "➕ Cargar más facturas"}],
     [{"dato": "/cancelar", "texto": "✖️ Cancelar"}]]'),
  ('mercado.pedir_facturas',
   'Listo: <b>Mercado de compras</b>.

Para este informe necesito tus <b>facturas de compra</b>: los XML de la DIAN que te mandan tus proveedores, o el archivo de compras que exporte tu sistema (Excel o CSV). Mandámelos acá.',
   'html', '[]',
   '[[{"dato": "/cancelar", "texto": "✖️ Cancelar"}]]'),
  ('informe.titular_seco.mercado_compras',
   'Esto es lo que encontré en tus compras',
   'html', '[]', '[]')
ON CONFLICT (clave) DO UPDATE
  SET cuerpo = EXCLUDED.cuerpo, formato = EXCLUDED.formato,
      variables = EXCLUDED.variables, teclado = EXCLUDED.teclado,
      activo = true, version = plantillas.version + 1;

-- === 5. Informe seco: rama de compras =======================================
-- Despacha por la forma de los hallazgos, como manda la 031: si traen
-- gasto_producto, es el informe de compras.

CREATE OR REPLACE FUNCTION informe_estructura_seca(p_hallazgos jsonb,
                                                   p_servicio  text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_h    jsonb := coalesce(p_hallazgos, '{}'::jsonb);
    v_sec  jsonb := '[]'::jsonb;
    v_pts  jsonb;   -- hasta 3 puntos por sección, como hacía el nodo Code
BEGIN
    -- Las cifras se copian tal cual del JSON de hallazgos, sin reformatear: son
    -- exactamente las que validar_cifras daría por buenas.
    -- --- Servicios de conocimiento (consulta, y mañana el cotizador) --------
    IF jsonb_typeof(v_h -> 'hechos') = 'array'
       AND jsonb_array_length(v_h -> 'hechos') > 0 THEN
        SELECT jsonb_agg(btrim(coalesce(nullif(e ->> 'contenido', ''), e ->> 'titulo')))
          INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(v_h -> 'hechos') e LIMIT 3) s;

        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '🔎', 'titulo', 'Lo que tengo cargado', 'puntos', v_pts));
        END IF;
    -- --- Mercado de compras (043) -------------------------------------------
    ELSIF v_h ? 'gasto_producto' THEN
        SELECT jsonb_agg(format('%s: %s%% del gasto ($%s)',
                                e ->> 'producto', e ->> 'pct_gasto',
                                miles((e ->> 'gasto')::numeric))) INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(coalesce(v_h->'gasto_producto','[]'::jsonb)) e
              LIMIT 3) s;
        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '💰', 'titulo', 'Se te va la plata en', 'puntos', v_pts));
        END IF;

        SELECT jsonb_agg(format('%s: el costo se movió %s%%',
                                e ->> 'producto', e ->> 'deriva_pct')) INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(coalesce(v_h->'deriva_costo','[]'::jsonb)) e
              LIMIT 3) s;
        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '📈', 'titulo', 'Les subió el costo', 'puntos', v_pts));
        END IF;

        SELECT jsonb_agg(format('%s: pagaste entre $%s y $%s (%s%%)',
                                e ->> 'producto', miles((e ->> 'precio_min')::numeric),
                                miles((e ->> 'precio_max')::numeric),
                                e ->> 'dispersion_pct')) INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(coalesce(v_h->'precio_disperso','[]'::jsonb)) e
              LIMIT 3) s;
        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '🔎', 'titulo', 'Precios muy distintos', 'puntos', v_pts));
        END IF;

        SELECT jsonb_agg(format('%s: compraste %s unidades y no registra ventas',
                                e ->> 'producto', e ->> 'unidades')) INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(coalesce(v_h->'sin_venta','[]'::jsonb)) e
              LIMIT 3) s;
        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '📦', 'titulo', 'Comprado sin vender', 'puntos', v_pts));
        END IF;
    ELSE
        -- --- Análisis de ventas y compras -----------------------------------
        SELECT jsonb_agg(format('%s: deja %s%% de margen',
                                e ->> 'producto', e ->> 'margen_pct')) INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(coalesce(v_h->'margen_bajo','[]'::jsonb)) e
              LIMIT 3) s;
        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '⚠️', 'titulo', 'Margen bajo', 'puntos', v_pts));
        END IF;

        SELECT jsonb_agg(format('%s: el costo se movió %s%%',
                                e ->> 'producto', e ->> 'deriva_pct')) INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(coalesce(v_h->'deriva_costo','[]'::jsonb)) e
              LIMIT 3) s;
        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '📈', 'titulo', 'Les subió el costo', 'puntos', v_pts));
        END IF;

        SELECT jsonb_agg(format('%s: alcanza para %s días',
                                e ->> 'producto', e ->> 'dias_cobertura')) INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(coalesce(v_h->'baja_cobertura','[]'::jsonb)) e
              LIMIT 3) s;
        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '🕐', 'titulo', 'Se agotan pronto', 'puntos', v_pts));
        END IF;

        SELECT jsonb_agg(format('%s: aporta %s%% de la utilidad',
                                e ->> 'producto', e ->> 'pct_utilidad')) INTO v_pts
        FROM (SELECT e FROM jsonb_array_elements(coalesce(v_h->'pareto','[]'::jsonb)) e
              LIMIT 3) s;
        IF v_pts IS NOT NULL THEN
            v_sec := v_sec || jsonb_build_array(jsonb_build_object(
                'icono', '🏆', 'titulo', 'Concentran la ganancia', 'puntos', v_pts));
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'titular', plantilla_cuerpo_srv('informe.titular_seco', p_servicio,
                     'Esto es lo que encontré en tus números'),
        'secciones', v_sec,
        'acciones', '[]'::jsonb,
        'narrado', false);
END;
$$;

-- === 6. Verificación de compras previas =====================================

CREATE OR REPLACE FUNCTION mercado_compras_bienvenida(p_negocio_id bigint,
                                                      p_chat_id bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v record;
BEGIN
    SELECT count(DISTINCT m.documento_id)                              AS documentos,
           count(DISTINCT coalesce(p.nombre_canonico,
                 m.raw ->> 'descripcion', m.raw ->> 'producto'))       AS productos,
           round(coalesce(sum(m.valor_total), 0))                      AS gasto,
           min(m.fecha) AS desde, max(m.fecha) AS hasta
    INTO v
    FROM movimientos m
    LEFT JOIN productos p ON p.id = m.producto_id
    WHERE m.negocio_id = p_negocio_id AND m.tipo = 'compra';

    IF coalesce(v.documentos, 0) = 0 THEN
        RETURN router_respuesta(p_chat_id, 'mercado.pedir_facturas');
    END IF;

    RETURN router_respuesta(p_chat_id, 'mercado.datos_previos', jsonb_build_object(
        'documentos', v.documentos,
        'productos',  v.productos,
        'gasto',      '$' || miles(v.gasto),
        'rango',      coalesce(' ' || nullif(periodo_es(v.desde, v.hasta), ''), '')));
END;
$$;

-- === 7. Router ==============================================================
-- Copia de la 042 con dos agregados marcados con ">>> 043":
--   * al elegir mercado_compras, la bienvenida verifica compras previas;
--   * /listo corre sin archivos de sesión si el servicio es mercado_compras
--     y el negocio ya tiene compras.

CREATE OR REPLACE FUNCTION router_procesar_mensaje(p_evento jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_usuario_id bigint;
    v_chat_id    bigint  := (p_evento #>> '{chat,id}')::bigint;
    v_texto      text    := btrim(coalesce(p_evento ->> 'texto', ''));
    v_cmd        text;
    v_svc        text;          -- código que llegó por botón (svc:<codigo>)
    v_arg        text;          -- resto del mensaje después del comando
    v_tiene_doc  boolean := coalesce((p_evento ->> 'tiene_documento')::boolean, false);
    v_sesion     record;
    v_negocio_id bigint;
    v_autoriz    boolean;
    v_rol        rol_usuario;
    v_servicio   record;
    v_n_serv     int;
    v_consulta   boolean;
    v_ejec_id    bigint;
    v_nueva_ses  bigint;
    v_titulo     text;
BEGIN
    -- El primer token y el resto. Se parte por espacio EN BLANCO, no por ' ':
    -- un "/saber" seguido de salto de línea es la forma natural de enseñarle
    -- algo largo, y con split_part(' ') el comando se comía el texto entero.
    v_cmd := lower(coalesce(substring(v_texto FROM '^\S+'), ''));
    v_arg := btrim(coalesce(substring(v_texto FROM '^\S+\s+(.*)$'), ''));
    IF v_texto LIKE 'svc:%' THEN
        v_svc := substring(v_texto FROM 5);
        v_cmd := 'svc';
    END IF;

    v_usuario_id := usuario_de_canal('telegram', p_evento);
    SELECT negocio_id, autorizacion_datos, rol
      INTO v_negocio_id, v_autoriz, v_rol
    FROM usuarios WHERE id = v_usuario_id;

    -- Solo los de archivos: los de texto no se eligen de una lista.
    SELECT count(*) INTO v_n_serv
    FROM servicios WHERE activo AND entrada = 'archivos';
    SELECT EXISTS (SELECT 1 FROM servicios WHERE activo AND entrada = 'texto'
                     AND codigo = 'consulta') INTO v_consulta;

    -- ---- Comandos de admin -------------------------------------------------
    IF v_cmd IN ('/salud','/embudo','/fallas','/consumo','/matching','/admin') THEN
        IF v_rol <> 'admin' THEN
            RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
        END IF;
        RETURN router_respuesta(v_chat_id, admin_reporte(v_cmd));
    END IF;

    SELECT * INTO v_sesion FROM sesiones
    WHERE usuario_id = v_usuario_id AND cerrada_en IS NULL
    ORDER BY id DESC LIMIT 1;
    IF v_sesion.id IS NOT NULL THEN
        UPDATE sesiones SET ultima_actividad = now() WHERE id = v_sesion.id;
    END IF;

    -- ---- Informativos: accesibles incluso sin autorizar --------------------
    IF v_cmd IN ('/start','/help','/ayuda') THEN
        RETURN router_respuesta(v_chat_id, 'sistema.bienvenida');
    END IF;
    IF v_cmd = '/comofunciona' THEN
        RETURN router_respuesta(v_chat_id, 'sistema.como_funciona');
    END IF;
    IF v_cmd = '/privacidad' THEN
        RETURN router_respuesta(v_chat_id, 'sistema.privacidad');
    END IF;

    -- ---- Autorización de datos (una sola vez) ------------------------------
    IF NOT v_autoriz THEN
        IF lower(v_texto) IN ('acepto','autorizo','si','sí','ok','dale') THEN
            UPDATE usuarios SET autorizacion_datos = true, autorizacion_fecha = now()
            WHERE id = v_usuario_id;
            RETURN router_respuesta(v_chat_id, 'sistema.bienvenida');
        END IF;
        RETURN router_respuesta(v_chat_id, 'sistema.no_autorizado');
    END IF;

    -- ---- /portal: el enlace de un solo uso ---------------------------------
    -- Todo lo que necesite más de un turno o más de un campo vive allá; en el
    -- chat es un enlace y nada más.
    IF v_cmd IN ('/portal','/web') THEN
        RETURN router_portal(v_usuario_id, v_chat_id);
    END IF;

    -- Plan, consumo del mes y enlace de pago si el operador lo configuró.
    IF v_cmd = '/plan' THEN
        RETURN router_plan(v_negocio_id, v_chat_id);
    END IF;

    -- ---- /saber: el dueño le enseña algo al bot ----------------------------
    -- Sin tipo ni clave: lo que entra por chat es un hecho suelto. Clasificarlo
    -- y darle estructura es trabajo del portal, que tiene pantalla para eso.
    IF v_cmd = '/saber' THEN
        -- Sin negocio asignado no hay dónde guardar el hecho; el usuario
        -- tampoco puede hacer nada más en el bot hasta que se lo asignen.
        IF v_negocio_id IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
        END IF;
        IF v_arg = '' THEN
            RETURN router_respuesta(v_chat_id, 'conocimiento.saber_vacio');
        END IF;
        -- El título es la primera frase (o los primeros 80 caracteres): es lo
        -- que se muestra en las listas y lo que más pesa en la búsqueda.
        v_titulo := btrim(split_part(v_arg, '.', 1));
        IF char_length(v_titulo) > 80 OR v_titulo = '' THEN
            v_titulo := btrim(left(v_arg, 80));
        END IF;
        PERFORM conocimiento_guardar(v_negocio_id, 'faq', v_titulo, v_arg,
                                     NULL, '{}'::jsonb, 'chat', v_usuario_id);
        RETURN router_respuesta(v_chat_id, 'conocimiento.guardado',
                 jsonb_build_object('titulo', v_titulo));
    END IF;

    -- ---- Cancelar ----------------------------------------------------------
    IF v_cmd IN ('/cancelar','/cancel') THEN
        IF v_sesion.id IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.sin_sesion');
        END IF;
        UPDATE sesiones SET estado = 'expirada', cerrada_en = now()
        WHERE usuario_id = v_usuario_id AND cerrada_en IS NULL;
        RETURN router_respuesta(v_chat_id, 'sesion.cancelada');
    END IF;

    -- ---- /nueva ------------------------------------------------------------
    IF v_cmd = '/nueva' THEN
        UPDATE sesiones SET estado = 'expirada', cerrada_en = now()
        WHERE usuario_id = v_usuario_id AND cerrada_en IS NULL;

        IF v_n_serv = 1 THEN
            SELECT * INTO v_servicio FROM servicios
            WHERE activo AND entrada = 'archivos' LIMIT 1;
            INSERT INTO sesiones (usuario_id, negocio_id, servicio_codigo, estado, paso)
            VALUES (v_usuario_id, v_negocio_id, v_servicio.codigo, 'recibiendo', 'cargar_archivos');
            RETURN router_respuesta(v_chat_id, 'sistema.pedir_archivos',
                     jsonb_build_object('servicio', v_servicio.nombre));
        END IF;

        INSERT INTO sesiones (usuario_id, negocio_id, estado, paso)
        VALUES (v_usuario_id, v_negocio_id, 'intake', 'elegir_servicio');
        RETURN router_respuesta(v_chat_id, 'sistema.elegir_servicio',
                 '{}'::jsonb, teclado_servicios());
    END IF;

    -- ---- Sin sesión abierta ------------------------------------------------
    IF v_sesion.id IS NULL THEN
        IF v_tiene_doc AND v_n_serv = 1 THEN
            SELECT * INTO v_servicio FROM servicios
            WHERE activo AND entrada = 'archivos' LIMIT 1;
            INSERT INTO sesiones (usuario_id, negocio_id, servicio_codigo, estado, paso)
            VALUES (v_usuario_id, v_negocio_id, v_servicio.codigo, 'recibiendo', 'cargar_archivos')
            RETURNING id INTO v_nueva_ses;
            RETURN router_respuesta(v_chat_id, 'sistema.archivo_sin_sesion',
                     jsonb_build_object('servicio', v_servicio.nombre), NULL,
                     jsonb_build_array(jsonb_build_object(
                       'tipo','ingerir','sesion_id', v_nueva_ses)));
        END IF;
        IF v_tiene_doc THEN
            RETURN router_respuesta(v_chat_id, 'sistema.elegir_servicio',
                     '{}'::jsonb, teclado_servicios());
        END IF;

        -- Texto libre = pregunta. Va último a propósito: cualquier cosa que
        -- empiece con '/' es un comando que no existe, no una pregunta, y un
        -- 'svc:' es un botón rancio del historial.
        IF v_consulta AND v_texto <> '' AND left(v_texto, 1) <> '/' AND v_cmd <> 'svc' THEN
            RETURN consulta_iniciar(v_usuario_id, v_negocio_id, v_chat_id, v_texto);
        END IF;

        RETURN router_respuesta(v_chat_id, 'sistema.sin_sesion');
    END IF;

    -- ---- Ya se está ejecutando: nada de disparar una segunda corrida -------
    IF v_sesion.estado = 'procesando' THEN
        RETURN router_respuesta(v_chat_id, 'ejecucion.ya_en_curso');
    END IF;

    -- ---- Intake: elegir servicio ------------------------------------------
    IF v_sesion.estado = 'intake' AND v_sesion.paso = 'elegir_servicio' THEN
        IF v_cmd = 'svc' THEN
            SELECT * INTO v_servicio FROM servicios
            WHERE activo AND entrada = 'archivos' AND codigo = v_svc;
        ELSIF v_tiene_doc AND v_n_serv = 1 THEN
            SELECT * INTO v_servicio FROM servicios
            WHERE activo AND entrada = 'archivos' LIMIT 1;
        ELSE
            SELECT * INTO v_servicio FROM servicios
            WHERE activo AND entrada = 'archivos'
              AND (norm_texto(nombre) LIKE '%'||norm_texto(v_texto)||'%'
                   OR norm_texto(v_texto) LIKE '%'||norm_texto(nombre)||'%'
                   OR codigo = lower(v_texto))
            ORDER BY orden LIMIT 1;
        END IF;

        IF v_servicio.codigo IS NULL THEN
            RETURN router_respuesta(v_chat_id, 'sistema.servicio_no_reconocido',
                     '{}'::jsonb, teclado_servicios());
        END IF;

        UPDATE sesiones SET servicio_codigo = v_servicio.codigo, estado = 'recibiendo',
               paso = 'cargar_archivos' WHERE id = v_sesion.id;

        IF v_tiene_doc THEN
            RETURN router_respuesta(v_chat_id, NULL, NULL, NULL,
                     jsonb_build_array(jsonb_build_object(
                       'tipo','ingerir','sesion_id', v_sesion.id)));
        END IF;

        -- >>> 043: mercado_compras primero verifica si ya hay compras
        -- cargadas y ofrece generar con eso o cargar más.
        IF v_servicio.codigo = 'mercado_compras' THEN
            RETURN mercado_compras_bienvenida(v_negocio_id, v_chat_id);
        END IF;

        RETURN router_respuesta(v_chat_id, 'sistema.pedir_archivos',
                 jsonb_build_object('servicio', v_servicio.nombre));
    END IF;

    -- ---- Recibiendo archivos ----------------------------------------------
    -- Acá el texto libre NO se desvía a consulta: el usuario está a mitad de un
    -- análisis y secuestrarle el turno con una respuesta de la KB haría perder
    -- los archivos que ya subió.
    IF v_sesion.estado = 'recibiendo' THEN
        IF v_tiene_doc THEN
            RETURN router_respuesta(v_chat_id, NULL, NULL, NULL,
                     jsonb_build_array(jsonb_build_object(
                       'tipo','ingerir','sesion_id', v_sesion.id)));
        END IF;

        IF v_cmd = 'svc' THEN
            RETURN router_respuesta(v_chat_id, 'sistema.servicio_ya_elegido',
                     jsonb_build_object('servicio',
                       (SELECT nombre FROM servicios WHERE codigo = v_sesion.servicio_codigo)));
        END IF;

        -- La pregunta "¿son todos?" se contesta acá (042).
        -- Sí -> el único resumen de la carga, con los botones de verdad.
        IF v_cmd = '/todos' THEN
            IF NOT EXISTS (SELECT 1 FROM documentos
                           WHERE sesion_id = v_sesion.id AND estado = 'parseado') THEN
                RETURN router_respuesta(v_chat_id, 'sistema.sin_documentos');
            END IF;
            RETURN router_respuesta(v_chat_id, 'ingesta.resumen_sesion',
                     ingesta_resumen_sesion(v_sesion.id));
        END IF;
        -- No -> a seguir esperando archivos, sin más botones.
        IF v_cmd = '/faltan' THEN
            RETURN router_respuesta(v_chat_id, 'ingesta.esperando_mas');
        END IF;

        IF v_cmd IN ('/listo','/analizar','/fin') THEN
            -- >>> 043: mercado_compras puede correr sin archivos en la sesión
            -- si el negocio ya tiene compras cargadas de antes.
            IF NOT EXISTS (SELECT 1 FROM documentos
                           WHERE sesion_id = v_sesion.id AND estado = 'parseado')
               AND NOT (v_sesion.servicio_codigo = 'mercado_compras'
                        AND EXISTS (SELECT 1 FROM movimientos
                                    WHERE negocio_id = v_negocio_id
                                      AND tipo = 'compra')) THEN
                RETURN router_respuesta(v_chat_id, 'sistema.sin_documentos');
            END IF;

            UPDATE sesiones SET estado = 'procesando', paso = 'ejecutando'
            WHERE id = v_sesion.id;
            INSERT INTO ejecuciones (sesion_id, negocio_id, servicio_codigo, estado)
            VALUES (v_sesion.id, v_negocio_id, v_sesion.servicio_codigo, 'preparando')
            RETURNING id INTO v_ejec_id;

            RETURN router_respuesta(v_chat_id, 'ejecucion.en_curso', '{}'::jsonb, NULL,
                     jsonb_build_array(jsonb_build_object(
                       'tipo','ejecutar','ejecucion_id', v_ejec_id)));
        END IF;

        RETURN router_respuesta(v_chat_id, 'sistema.esperando_listo');
    END IF;

    RETURN router_respuesta(v_chat_id, 'sistema.no_entendido');
END;
$$;
