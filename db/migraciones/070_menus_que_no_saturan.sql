-- 070_menus_que_no_saturan.sql — un menú reemplaza al anterior en vez de
-- apilarse.
--
-- EL PROBLEMA, OBSERVADO EN LA PRIMERA PRUEBA DE USUARIO
--
-- Cada toque de botón produce un mensaje nuevo. Navegar tres pantallas —abrir el
-- menú, entrar a un módulo, volver— deja tres mensajes con botones en el chat, y
-- ninguno de los dos primeros sirve ya para nada. El chat se llena de menús
-- muertos, que es lo contrario de lo que promete una conversación por botones:
-- que el usuario casi no tenga que leer para saber qué hacer ahora.
--
-- Lo que hacen los bots que se sienten prolijos es editar el mensaje que trae el
-- botón (`editMessageText`), de modo que la pantalla se actualiza en el lugar.
--
-- DÓNDE VIVE CADA MITAD DE LA DECISIÓN
--
-- Editar necesita dos cosas que están en lados distintos del sistema:
--
--   * QUÉ pantallas son reemplazables — eso es comportamiento, así que es un
--     dato: la columna `plantillas.reemplaza`. Marcar una pantalla nueva como
--     navegable es un UPDATE, igual que agregarle un botón.
--   * CUÁL es el mensaje a editar — eso solo lo sabe quien recibió el update:
--     `callback_query.message.message_id`, que vive en el workflow.
--
-- Por eso la base no decide sola: publica `reemplaza` en la respuesta y
-- `router_marcar_editables` le pega el `message_id` cuando el evento lo trae. Si
-- el mensaje llegó escrito (no hay `message_id`), o si el canal es WhatsApp
-- —donde editar no existe—, la respuesta sale como mensaje nuevo y nada cambia.
--
-- QUÉ SE MARCA Y QUÉ NO
--
-- Solo las pantallas de NAVEGACIÓN: menús, ayudas, el consentimiento, la lista
-- de recomendaciones y su detalle. No se marcan los informes, las confirmaciones
-- de archivo ni las de una acción: un informe que pisa al anterior sería peor
-- que la saturación, y una confirmación que se come la lista deja al usuario sin
-- el contexto desde el que actuó.
--
-- POR QUÉ ENVOLVER Y NO TOCAR `router_respuesta`
--
-- `router_respuesta` es IMMUTABLE y la usan los seis handlers. Leer `plantillas`
-- desde ahí la volvería STABLE y obligaría a repuntar toda la cadena. El
-- envoltorio se aplica una sola vez, en el nodo que ya llamaba al router, y
-- ningún handler se entera.

-- =============================================================================
-- 1. Qué pantalla reemplaza a la anterior
-- =============================================================================
ALTER TABLE plantillas
    ADD COLUMN IF NOT EXISTS reemplaza boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN plantillas.reemplaza IS
  'Pantalla de navegación: cuando la dispara un botón, edita ese mensaje en vez '
  'de mandar uno nuevo. Falso para informes, confirmaciones y resultados.';

UPDATE plantillas SET reemplaza = true
 WHERE clave IN (
   -- El recorrido del menú, incluida la vuelta atrás.
   'sistema.bienvenida',
   'sistema.modulo',
   'sistema.modulo_ayuda',
   'sistema.como_funciona',
   'sistema.privacidad',
   'sistema.elegir_servicio',
   -- El permiso y lo que viene inmediatamente después: aceptar reemplaza el
   -- consentimiento, elegir el tipo reemplaza la pregunta, y así hasta la
   -- pantalla que queda esperando archivos.
   'sistema.consentimiento',
   'sistema.pedir_tipo',
   'sistema.pedir_archivos',
   'mercado.pedir_facturas',
   'mercado.datos_previos',
   -- Las dos pantallas de D1: lista y detalle de una recomendación.
   'recomendacion.lista',
   'recomendacion.detalle',
   'recomendacion.sin_pendientes');

-- =============================================================================
-- 2. El envoltorio
-- =============================================================================
-- Recibe lo que devolvió el router y el evento, y le agrega `editar` a las
-- respuestas cuya plantilla esté marcada. Nada más: no reordena, no filtra, y
-- si no hay nada que editar devuelve su entrada tal cual.
CREATE OR REPLACE FUNCTION router_marcar_editables(p_res jsonb, p_evento jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT CASE
      -- Sin mensaje que editar (llegó escrito, o es WhatsApp) no hay nada que
      -- hacer. Es el camino de siempre y tiene que salir intacto.
      WHEN nullif(p_evento ->> 'message_id', '') IS NULL
        OR jsonb_array_length(coalesce(p_res -> 'respuestas', '[]'::jsonb)) = 0
      THEN p_res
      ELSE jsonb_set(p_res, '{respuestas}', (
        SELECT jsonb_agg(
                 CASE WHEN coalesce(pl.reemplaza, false)
                      THEN e.r || jsonb_build_object('editar',
                             (p_evento ->> 'message_id')::bigint)
                      ELSE e.r END
                 ORDER BY e.ord)
        FROM jsonb_array_elements(p_res -> 'respuestas')
             WITH ORDINALITY AS e(r, ord)
        LEFT JOIN plantillas pl ON pl.clave = e.r ->> 'plantilla'))
    END;
$$;

COMMENT ON FUNCTION router_marcar_editables(jsonb, jsonb) IS
  'Le pega el message_id del botón tocado a las respuestas cuya plantilla sea '
  'de navegación (plantillas.reemplaza). Sin message_id devuelve su entrada.';
