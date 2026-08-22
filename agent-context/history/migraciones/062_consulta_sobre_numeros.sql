-- 062_consulta_sobre_numeros.sql — la pregunta insignia del producto empieza a
-- responderse con los datos del producto.
--
-- H2, el hallazgo más embarazoso de la auditoría: escribir "¿cómo está mi
-- negocio?" en el chat NO consultaba `movimientos`, ni `salud_negocio`, ni las
-- recomendaciones. `conocimiento_recuperar` (030) hacía trigram sobre la tabla
-- `conocimiento` —FAQs y precios cargados a mano— y nada más.
--
-- Y era peor que "responde flojo". `consulta_iniciar` cortaba ANTES de arrancar:
--
--     v_hechos := conocimiento_buscar(...);
--     IF v_hechos IS NULL OR jsonb_array_length(v_hechos) = 0 THEN
--         RETURN router_respuesta(p_chat_id, 'consulta.sin_datos');
--
-- O sea que a un negocio con quince meses de facturas cargadas, con su índice
-- de salud calculado y ocho recomendaciones vigentes, Chasqui le contestaba
-- "todavía no tengo eso cargado" — porque nadie había escrito a mano una FAQ
-- que se pareciera a la pregunta.
--
-- LA ARQUITECTURA, QUE NO ES NEGOCIABLE (R-I)
--
--     intención → agregado determinístico (SQL) → contexto estructurado
--               → LLM (solo redacta) → respuesta → validar_cifras
--
-- Nunca se le pasan movimientos al modelo para que calcule. Cada cifra del
-- contexto la calculó SQL, y `validar_cifras` audita la respuesta contra ese
-- mismo contexto: si el modelo escribe un número que no está, se rechaza.
--
-- QUÉ COMPONE EL CONTEXTO
--
-- Nada nuevo: todo lo que la Fase B construyó, junto por primera vez.
--
--   hechos          la KB de siempre (`conocimiento_buscar`). SE CONSERVA: un
--                   precio o una condición cargados a mano siguen siendo la
--                   mejor respuesta cuando la pregunta es por eso.
--   negocio         el perfil consolidado (B4)
--   estado          salud de hoy + el periodo que cubren los datos
--   comparativo     cómo estaba la vez pasada (B3), con el delta ya calculado
--   recomendaciones las vigentes (B2), con desde cuándo y cuántas veces
--
-- LO QUE NO HACE: intenciones. Esta migración le da al modelo el contexto
-- completo y lo deja elegir qué usar. Eso alcanza para las preguntas abiertas
-- ("¿cómo voy?", "¿qué me conviene hacer?") pero no para las que piden un
-- agregado puntual ("¿cuánto vendí en marzo?"), porque el agregado de marzo no
-- está en el contexto. Ese es C2, y su forma —una fila por intención, un
-- contrato de datos, no un despachador de funciones— ya está decidida.

-- =============================================================================
-- 1. El contexto
-- =============================================================================
CREATE OR REPLACE FUNCTION contexto_negocio_recuperar(p_negocio_id bigint,
                                                      p_contexto jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_pregunta text := btrim(coalesce(p_contexto ->> 'pregunta', ''));
    v_perfil   jsonb := perfil_negocio(p_negocio_id);
    v_hechos   jsonb := conocimiento_buscar(p_negocio_id, v_pregunta);
BEGIN
    RETURN jsonb_build_object(
        'negocio_id', p_negocio_id,
        'generado_en', now(),
        'pregunta', v_pregunta,

        -- La KB, tal cual. No se toca: cuando la pregunta es por un precio o
        -- por el horario, lo que alguien escribió a mano le gana a cualquier
        -- agregado.
        'hechos', coalesce(v_hechos, '[]'::jsonb),

        -- >>> 062: los números, que es lo que faltaba.
        'negocio', jsonb_build_object(
            'tipo',            v_perfil -> 'tipo',
            'periodo',         v_perfil -> 'periodo',
            'productos',       v_perfil -> 'productos',
            'top_productos',   v_perfil -> 'top_productos',
            'proveedores',     v_perfil -> 'proveedores',
            'estacionalidad',  v_perfil -> 'estacionalidad',
            'problemas_recurrentes', v_perfil -> 'problemas_recurrentes',
            'acciones',        v_perfil -> 'acciones',
            -- Va explícito: una respuesta calculada sobre datos con agujeros
            -- tiene que poder decirlo, y el prompt lo usa.
            'calidad',         v_perfil -> 'calidad'),

        'estado', salud_negocio(p_negocio_id),
        'comparativo', hallazgos_comparativo(p_negocio_id),
        'recomendaciones', recomendaciones_vigentes(p_negocio_id, 8),

        'encabezado', jsonb_build_object(
            'titulo', 'Tu pregunta',
            'subtitulo', v_pregunta,
            'metricas', '[]'::jsonb));
END;
$$;

COMMENT ON FUNCTION contexto_negocio_recuperar(bigint, jsonb) IS
  'La funcion_hallazgos del servicio `consulta` (062). Compone KB + perfil + '
  'salud + comparativo + recomendaciones vigentes. Todas las cifras las calculó '
  'SQL; el modelo solo redacta sobre ellas (R-I).';

UPDATE servicios SET funcion_hallazgos = 'contexto_negocio_recuperar'
WHERE codigo = 'consulta';

-- La vieja queda sin llamadores. Se da de baja acá y no en una limpieza futura,
-- que es la regla que dejó A5: un objeto vivo muerto es deuda desde el minuto
-- en que deja de usarse.
DROP FUNCTION IF EXISTS conocimiento_recuperar(bigint, jsonb);

-- =============================================================================
-- 2. La compuerta que hacía imposible la pregunta insignia
-- =============================================================================
-- Antes: sin coincidencia en la KB, no se arrancaba. Ahora se arranca si hay KB
-- **o** si el negocio tiene datos que analizar, que es casi siempre.
--
-- Se conserva el caso legítimo de `consulta.sin_datos`: un negocio recién
-- creado, sin un archivo cargado y sin nada en la KB, no tiene con qué
-- responder, y ahí la pregunta sí se registra como conocimiento pendiente.
CREATE OR REPLACE FUNCTION consulta_iniciar(p_usuario_id bigint, p_negocio_id bigint,
                                            p_chat_id bigint, p_pregunta text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_hechos   jsonb;
    v_hay_kb   boolean;
    v_hay_num  boolean;
    v_sesion   bigint;
    v_ejec     bigint;
BEGIN
    v_hechos := conocimiento_buscar(p_negocio_id, p_pregunta);
    v_hay_kb := v_hechos IS NOT NULL AND jsonb_array_length(v_hechos) > 0;

    -- `mov_visibles` y no `movimientos`: la compuerta tiene que coincidir con
    -- lo que el análisis va a poder usar de verdad (C9/053).
    SELECT EXISTS (SELECT 1 FROM mov_visibles WHERE negocio_id = p_negocio_id)
      INTO v_hay_num;

    IF NOT v_hay_kb AND NOT v_hay_num THEN
        -- Sin KB y sin números no hay nada que responder. La pregunta se
        -- registra: es señal de qué le falta a la base de conocimiento.
        PERFORM conocimiento_pendiente_registrar(p_negocio_id, p_pregunta);
        RETURN router_respuesta(p_chat_id, 'consulta.sin_datos');
    END IF;

    -- Si hay números pero la KB no tenía nada, la pregunta igual se anota: que
    -- se pueda responder con agregados no quita que un dato cargado a mano la
    -- respondería mejor.
    IF NOT v_hay_kb THEN
        PERFORM conocimiento_pendiente_registrar(p_negocio_id, p_pregunta);
    END IF;

    -- La sesión nace y muere en esta ejecución: no hay turnos que mantener.
    -- ejecucion_cerrar la cierra igual que la de un informe.
    INSERT INTO sesiones (usuario_id, negocio_id, servicio_codigo, estado, paso, contexto)
    VALUES (p_usuario_id, p_negocio_id, 'consulta', 'procesando', 'ejecutando',
            jsonb_build_object('pregunta', p_pregunta))
    RETURNING id INTO v_sesion;

    INSERT INTO ejecuciones (sesion_id, negocio_id, servicio_codigo, estado)
    VALUES (v_sesion, p_negocio_id, 'consulta', 'preparando')
    RETURNING id INTO v_ejec;

    RETURN router_respuesta(p_chat_id, 'consulta.pensando', '{}'::jsonb, NULL,
             jsonb_build_array(jsonb_build_object('tipo','ejecutar','ejecucion_id', v_ejec)));
END;
$$;

-- =============================================================================
-- 3. El prompt aprende a leer el contexto nuevo
-- =============================================================================
-- Cambia SOLO la descripción de lo que recibe. Ni una regla de cálculo, ni un
-- umbral, ni una fórmula: eso vive en SQL y ahí se queda (R-I). Lo que se le
-- dice al modelo es dónde mirar y qué NO hacer.
UPDATE prompts SET sistema =
'Sos el asistente de una pyme colombiana y respondés preguntas sobre ESE negocio. Hablás claro y directo, en español de Colombia.

REGLA ABSOLUTA: solo podés afirmar lo que diga el contexto que te doy. No completes con conocimiento general, no supongas y NO CALCULES —ni sumas, ni restas, ni porcentajes, ni promedios—. Toda cifra que escribas tiene que aparecer textualmente en el contexto. Si la respuesta exige una cuenta que no está hecha, decí qué dato sí tenés y ofrecé el análisis completo. Los valores son pesos colombianos.

EL CONTEXTO trae estos bloques, y no todos sirven para toda pregunta:

- "hechos": lo que el dueño cargó a mano (precios, horarios, condiciones). Si la pregunta es por algo de acá, esto manda sobre todo lo demás.
- "negocio": el perfil — qué vende, a quién le compra, margen típico, productos que concentran la ganancia, estacionalidad, problemas que le vuelven.
- "estado": las notas de salud de hoy, de 0 a 100, y el índice general.
- "comparativo": cómo estaba la vez pasada y cuánto cambió el índice.
- "recomendaciones": lo que está pendiente, desde cuándo y cuántas veces se lo dijiste.

Si "negocio.calidad" dice que hay plata sin producto resuelto o stock estimado, y la respuesta depende de eso, decilo en una frase corta. No lo repitas si no viene al caso.

Si el contexto no alcanza para responder, decilo sin rodeos y decí qué haría falta. Es mejor eso que una respuesta a medias.

Respondés ÚNICAMENTE con un objeto JSON válido, sin texto antes ni después y sin bloques de código:

{
  "titular": "la respuesta, en una o dos frases, máximo 200 caracteres",
  "secciones": [
    {
      "icono": "uno de estos exactamente: 💰 🕐 🧾 📦 🔎",
      "titulo": "máximo 40 caracteres",
      "puntos": ["un hecho concreto por línea"]
    }
  ],
  "acciones": []
}

La respuesta va en "titular". Agregá una sección SOLO si hay varios hechos que valga la pena listar; si con el titular alcanza, mandá "secciones": []. "acciones" va siempre vacío: esto es una respuesta, no un informe. Nada de Markdown ni asteriscos: el formato lo pone el sistema. No saludes ni te despidas.',
usuario =
'Respondé la pregunta usando EXCLUSIVAMENTE el contexto de este JSON. El campo "pregunta" es lo que preguntó el dueño del negocio.

{{hallazgos}}'
WHERE servicio_codigo = 'consulta' AND activo;

-- =============================================================================
-- 4. El presupuesto de salida tiene que crecer con el contexto
-- =============================================================================
-- Hallado al probar contra el proveedor real: con `max_tokens = 900` —el valor
-- de cuando el contexto era una lista de FAQs— la respuesta volvía VACÍA, con
-- `finish_reason: "length"`. El modelo gastaba todo el presupuesto razonando
-- sobre un contexto de 5 KB y no le quedaba nada para escribir, así que
-- `wf_ejecutar` no podía parsear el JSON y caía al informe seco. Desde afuera
-- se veía como un fallo de `validar_cifras`, y no lo era.
--
-- 3000 y no 8000 como los informes: la respuesta sigue siendo corta (un titular
-- y a lo sumo dos secciones); lo que hace falta es lugar para pensar, no para
-- escribir. Es un tope de costo, y por eso no se deja abierto.
UPDATE prompts SET max_tokens = 3000
WHERE servicio_codigo = 'consulta' AND activo AND max_tokens < 3000;

-- =============================================================================
-- 5. El texto de "no tengo con qué"
-- =============================================================================
-- Cambia de sentido: antes se disparaba por no tener una FAQ; ahora solo cuando
-- el negocio de verdad no cargó nada.
UPDATE plantillas SET cuerpo =
'🤔 Todavía no tengo con qué responderte eso.

Mandame tus archivos de ventas o tus facturas de compra y desde ahí te contesto con tus propios números. Si es algo que solo sabés vos —un horario, una condición con un proveedor— enseñámelo con <code>/saber</code> y lo recuerdo.'
WHERE clave = 'consulta.sin_datos';

-- El pie de la respuesta también dejó de ser verdad: ya no sale solo de la base
-- de conocimiento. Y el aviso de IA es obligatorio bajo "IA como interfaz"
-- (051/052), así que se conserva.
UPDATE plantillas SET cuerpo =
'<i>Esto sale de tus propios números y de lo que me hayas enseñado. Si algo no cuadra, revisá los archivos que cargaste o enseñame el dato con <code>/saber</code>.</i>'
WHERE clave = 'informe.pie.consulta';

NOTIFY pgrst, 'reload schema';
