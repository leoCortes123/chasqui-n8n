-- 048_formatos_reales.sql — el mensaje de carga prometía PDF.
--
-- La 046 reescribió `sistema.pedir_archivos` para dejar de nombrar la DIAN y
-- listó "Excel, CSV, XML de factura electrónica y PDF". Los tres primeros son
-- ciertos; el PDF no: `parametros.ingesta_extractores` acepta csv, tsv, txt,
-- xls, xlsx y ods, y `formatos_documento` de clase 'documento' solo tiene
-- dian_xml. Un PDF entra y sale con "no sé leer archivos pdf", que es el peor
-- momento posible para enterarse.
--
-- La lista se saca de la base y no se escribe a mano, para que no vuelva a
-- desincronizarse: si mañana se agrega un extractor, el mensaje lo dice solo.

CREATE OR REPLACE FUNCTION extensiones_aceptadas() RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT string_agg(DISTINCT upper(ext), ', ' ORDER BY upper(ext))
    FROM (
        SELECT jsonb_object_keys(parametro(NULL, 'ingesta_extractores')) AS ext
        UNION
        SELECT unnest(extensiones) FROM formatos_documento
         WHERE activo AND clase = 'documento'
    ) t;
$$;

UPDATE plantillas SET cuerpo =
'Listo: <b>{{servicio}}</b>.

Mandame los archivos de <b>facturación</b> de tu negocio: las <b>ventas</b> y las <b>compras</b>. De dónde salgan no me importa —lo que exporte tu sistema, lo que te pase el contador, un Excel que llevés a mano— y tampoco cómo se llamen las columnas: yo los leo.

📎 Me sirven archivos {{formatos}}.

📅 <b>Cuánta historia mandarme:</b> con <b>3 meses</b> ya sale un análisis serio. Entre más me mandes, mejor: las tendencias de costo y lo que rota lento no se ven en dos semanas.

Empezá a mandarlos de a uno. Te voy diciendo qué leí de cada archivo, y ahí mismo te dejo el botón para analizar cuando estés listo.',
  variables = '["servicio","formatos"]'::jsonb,
  version = version + 1
WHERE clave = 'sistema.pedir_archivos';

-- router_arranque_servicio pasa la lista ya armada.
CREATE OR REPLACE FUNCTION router_arranque_servicio(p_negocio_id bigint,
                                                    p_chat_id    bigint,
                                                    p_servicio   text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_nombre text;
    v_tipo   text;
BEGIN
    SELECT nombre INTO v_nombre FROM servicios WHERE codigo = p_servicio;
    SELECT nullif(btrim(coalesce(tipo, '')), '') INTO v_tipo
    FROM negocios WHERE id = p_negocio_id;

    -- Sin negocio asignado no hay dónde guardar el tipo: no se pregunta lo que
    -- no se puede responder.
    IF p_negocio_id IS NOT NULL AND v_tipo IS NULL THEN
        RETURN router_respuesta(p_chat_id, 'sistema.pedir_tipo',
                 '{}'::jsonb, teclado_tipos_negocio());
    END IF;

    IF p_servicio = 'mercado_compras' THEN
        RETURN mercado_compras_bienvenida(p_negocio_id, p_chat_id);
    END IF;

    RETURN router_respuesta(p_chat_id, 'sistema.pedir_archivos',
             jsonb_build_object('servicio', v_nombre,
                                'formatos', extensiones_aceptadas()));
END;
$$;

NOTIFY pgrst, 'reload schema';
