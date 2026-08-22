# Dominio: canales

## Estado por canal

| Canal | Workflow | Activo en n8n | Operativo | Evidencia |
|---|---|---|---|---|
| **Telegram** | `wf_router` | sí (`triggerCount=1`) | sí para entrada; **la salida está rechazando** | 51 fallas `Forbidden` en `fallas` desde 2026-08-19 13:41 |
| **WhatsApp** | `wf_wa_router` | sí (`triggerCount=2`) | **no** | `WA_PHONE_NUMBER_ID` vacío en `.env`; el `Normalizar` descarta todo y las URLs de envío quedaron sin id |
| **Portal web** | — (PostgREST) | — | sí, si `parametros.portal_url_base` tiene valor | hoy tiene el túnel `https://adelaide-gets-emma-directories.trycloudflare.com` |

## Cómo se abstrae el canal `[CONFIRMADO]`

Tres funciones son toda la abstracción:

| Función | Qué resuelve |
|---|---|
| `usuario_de_canal(canal, evento)` | crea/recupera `usuarios` + `identidades`; el canal sale de `evento->>'canal'`, con `'telegram'` como parámetro por defecto |
| `canal_de_chat(chat_id)` | busca en `identidades` por `datos->>'chat_id'`, más reciente primero; **default `'telegram'`** |
| `chat_de_usuario(usuario_id)` | inverso; `identidades` primero, `usuarios.telegram_chat_id` como respaldo |

`[CONFIRMADO]` `ROUTER-001` invariante 3 se cumple: el canal viaja en el evento
normalizado, no en el nombre de la función. `router_procesar_mensaje` es una
sola función para los dos canales.

## Telegram — entrada

`[CONFIRMADO]` `bin/gen_wf_router.py`:

1. Webhook `POST /webhook/<TELEGRAM_WEBHOOK_PATH>`, `responseMode: onReceived`
   (200 inmediato).
2. `Normalizar` (JS): compara `x-telegram-bot-api-secret-token` contra el
   secreto **embebido al generar**; si no coincide, `return []` — descarte
   silencioso. Normaliza `message`, `edited_message` y `callback_query.message`
   al mismo evento.
3. `EsBoton?` → si hay `callback_id`, `answerCallbackQuery` (con
   `onError: continueRegularOutput`, porque un callback vencido devuelve 400
   «query is too old» y eso no puede bloquear el mensaje).
4. `Router`: `SELECT router_marcar_editables(router_procesar_mensaje(ev), ev)`.
5. `Despachar` (JS) → `Switch` por `tipo` → sub-workflows.

## Telegram — salida

`[CONFIRMADO]` `wf_enviar` es el único emisor. Tres ramas:

| Rama | Entrada | Nodos |
|---|---|---|
| texto | `{chat_id, respuestas[]}` | `Expandir` → `Resolver` (`resolver_plantilla` + `canal_de_chat` + `wa_payload`) → `Filas` → `EsEdicion?` → 7 nodos `EnviarTexto{0..6}` o 7 `EditarTexto{0..6}` |
| panel | `{chat_id, panel:{sesion_id, modo}}` | `PanelResolver` (`carga_panel`) → `PanelFilas` → crear (3 nodos) + `PanelGuardar` + `PanelFijar`, o editar (3 nodos) |
| documento | binario + `respuestas[].documento` | `CanalDoc` → `PrepDoc` → `EnviarDoc` (Telegram) o `WaSubirDoc`+`WaMandarDoc` |

`[CONFIRMADO]` **Por qué 7 nodos de envío**: el nodo Telegram de n8n resuelve
sus parámetros contra la descripción del nodo y descarta lo no declarado, así
que la **forma** del teclado (cuántas filas) tiene que ser literal en el
workflow; sólo el texto del botón y su `callback_data` pueden salir de una
expresión. El generador documenta cinco sondas contra la API real que lo
demuestran. `MAX_FILAS = 6`, un botón por fila.

`[CONFIRMADO]` `parse_mode: HTML` explícito y `appendAttribution: false`. El
motivo del HTML está documentado: sin `parse_mode` el nodo fuerza Markdown
legacy, y un guion bajo suelto —`ventas_compras`— rompe el mensaje entero.
`resolver_plantilla` escapa las variables con `esc_html`, salvo las declaradas
en `plantillas.crudas`.

`[CONFIRMADO]` `EnviarTexto{k}` va **sin** `onError`: un mensaje que no llega es
un fallo real y tiene que verse. Ese es el motivo por el que hoy hay 51 fallas
registradas en vez de un silencio.

## El panel de carga `[CONFIRMADO]`

- Un solo mensaje por sesión, guardado en `sesiones.panel_mensaje_id`.
- `PanelGuardar` lee `$json.result.message_id` — el nodo de Telegram devuelve el
  **sobre** completo de la API, no `responseData.result`. El generador anota que
  usar la ruta equivocada dejaba `panel_mensaje_id` en NULL y cada refresco
  creaba un panel nuevo.
- `PanelFijar` fija el mensaje (`pinChatMessage`, `disable_notification`), con
  `onError: continueRegularOutput`.
- Si editar falla por «not modified» se descarta; por cualquier otro motivo
  (mensaje borrado, más de 48 h) cae a crear uno nuevo, y `PanelGuardar` pisa el
  id, así que el panel «se muda» solo.

## WhatsApp `[CONFIRMADO]`

| Aspecto | Cómo está |
|---|---|
| Verificación de suscripción | `GET` sobre la misma ruta, compara `hub.verify_token` con `WA_VERIFY_TOKEN` embebido y responde `hub.challenge` |
| Autenticación de mensajes | **no verifica `X-Hub-Signature-256`**. Defensa: ruta secreta + descarte de todo update cuyo `phone_number_id` no coincida. Declarado como TODO en el generador |
| Normalización | un item por mensaje; los updates de estado (delivered/read) mueren en silencio, que es lo correcto |
| Botones | `interactive.button_reply.id` / `list_reply.id` se normalizan al mismo campo `texto` |
| Salida | `wa_texto()` convierte el HTML de Telegram a marcado de WhatsApp; `wa_payload()` arma el array de cuerpos para la Graph API (texto largo + interactivo corto = 2 mensajes; máximo 10 botones) |
| Panel | degrada a mensaje nuevo: `PanelEsTg?` desvía a `PartirWa`. WhatsApp no sabe editar ni fijar |
| Descarga de archivos | dos pasos: media id → URL firmada → binario, con el mismo Bearer (sin él responde 404, no 401 — anotado en el generador) |

### Diferencias de comportamiento no evidentes

`[CONTRADICCIÓN]` `wf_wa_router` **no maneja la acción `panel`**. Su `Switch`
tiene sólo 3 salidas (`enviar`, `ingerir`, `ejecutar`). Una acción `panel`
—que es lo que produce `router_h_recibiendo` al tocar `/listo` y lo que produce
`carga_evaluar`— cae fuera de las tres reglas y **se descarta en silencio**. En
WhatsApp el usuario no vería ningún panel de carga desde el router.

`[CONTRADICCIÓN]` `wf_wa_router` llama a `wf_ejecutar` **esperando**
(`waitForSubWorkflow` por defecto) y después llama a `EnviarInforme`. Pero
`wf_ejecutar` ya entrega su propio informe (nodo `EntregarInforme`). Por la rama
de WhatsApp el informe se enviaría **dos veces**, y además toda la generación
correría dentro del reloj de 300 s de la ejecución del router — exactamente el
problema que la rama de Telegram corrigió y documentó. `[INFERIDO]` El generador
de WhatsApp no se actualizó cuando se cambió `wf_ejecutar` para que entregara
por su cuenta.

`[CONFIRMADO]` `plantillas.canal` vale `'telegram'` en las 82 filas. No hay
plantillas específicas de WhatsApp; la conversión es puramente mecánica en
`wa_texto`.

## El registrador

`[CONFIRMADO]` `bin/registrar-webhook.sh` corre en el contenedor `registrador`
(perfil `local`) y hace tres cosas: descubre la URL del quick tunnel, registra
el webhook de Telegram (`setWebhook` con el secreto) y de WhatsApp si hay
credenciales, y escribe `parametros.portal_url_base` en la base. Es la única
pieza que conoce la URL pública del momento.

`[CONFIRMADO]` `parametros.portal_url_base` es **entorno guardado en una tabla
de producto**. El baseline la instala vacía a propósito (`BASE-001`), y con ella
vacía `/portal` responde `portal.sin_url` en vez de mandar un token a un dominio
que ya no es de nadie.
