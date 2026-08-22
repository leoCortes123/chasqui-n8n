# n8n — los 7 workflows

`[CONFIRMADO]` Los 7 existen, los 7 están **activos** en la base de n8n, y los 7
JSON del repo se reproducen byte a byte desde sus generadores
(`bin/verificar.sh` chequeo 1, corrido el 2026-08-19 sin violaciones).

| id | nombre | nodos (repo) | nodos (n8n) | trigger | activo |
|---|---|---|---|---|---|
| `wfRouter000000000001` | `wf_router` | 10 | 10 | Webhook POST | sí |
| `wfWaRouter0000000001` | `wf_wa_router` | 14 | 14 | Webhook GET + POST | sí |
| `wfIngesta00000000001` | `wf_ingesta` | 34 | 34 | Execute Workflow | sí |
| `wfEjecutar000000001` | `wf_ejecutar` | 29 | 29 | Execute Workflow | sí |
| `wfEnviar00000000001` | `wf_enviar` | 49 | 49 | Execute Workflow | sí |
| `wfCron00000000000001` | `wf_cron` | 6 | 6 | Schedule 5 min | sí |
| `wfError0000000000001` | `wf_error` | 6 | 6 | Error Trigger | sí |

`[CONFIRMADO]` Los JSON llevan `"active": false`; `bin/importar-workflows.sh`
importa, **publica** (`n8n publish:workflow`) y hace `UPDATE workflow_entity SET
active=true`. El script documenta por qué: en n8n 2.x «activo» y «publicado» son
cosas distintas, y `Execute Workflow` resuelve la versión **publicada**.

`[CONFIRMADO]` `wf_lib.WF.dump()` inyecta
`settings.errorWorkflow = wfError0000000000001` en todos menos en `wf_error`.

---

## wf_router

| | |
|---|---|
| Propósito | entrada de Telegram; único punto donde se llama al router |
| Trigger | Webhook `POST /webhook/${TELEGRAM_WEBHOOK_PATH}`, `responseMode: onReceived` |
| Entrada | update de Telegram |
| Salida | invoca `wf_enviar` / `wf_ingesta` / `wf_ejecutar` |
| SQL | `SELECT router_marcar_editables(router_procesar_mensaje(ev), ev) AS r` |
| Externas | `answerCallbackQuery` a Telegram |

Nodos: `Webhook` → `Normalizar` (JS: verifica secreto, normaliza) → `EsBoton?`
→ [`Responder`] → `Router` (Postgres) → `Despachar` (JS) → `Switch` (4 salidas)
→ `LlamarEnviar` / `LlamarIngesta` / `LlamarEjecutar`.

**Lógica de negocio en nodos**: ninguna. `Normalizar` y `Despachar` son
transporte. `[CONFIRMADO]` Es el workflow que mejor cumple la tesis.

**Errores**: un update sin secreto válido o sin `from.id` devuelve `[]` y muere
en silencio. `LlamarEjecutar` con `waitForSubWorkflow: false` y
`onError: continueRegularOutput`.

---

## wf_wa_router

| | |
|---|---|
| Propósito | entrada de WhatsApp Cloud API |
| Trigger | dos webhooks sobre la misma ruta: GET (challenge) y POST (mensajes) |
| SQL | `SELECT router_procesar_mensaje(ev) AS r` — **sin** `router_marcar_editables` |
| Salida | `wf_enviar`, `wf_ingesta`, `wf_ejecutar` **+ `EnviarInforme`** |

**Es integración, pero con dos diferencias de comportamiento que lo hacen
divergir del canal de Telegram** `[CONTRADICCIÓN]`:

1. Su `Switch` tiene **3** salidas (`enviar`, `ingerir`, `ejecutar`). La acción
   `panel` —que producen `router_h_recibiendo` y `carga_evaluar`— no tiene
   salida y se descarta en silencio.
2. `LlamarEjecutar` **espera** y después llama a `EnviarInforme`. Pero
   `wf_ejecutar` ya entrega su propio informe. Por WhatsApp el informe saldría
   dos veces, y la generación entera correría dentro del reloj de 300 s del
   router — el bug que la rama de Telegram corrigió.

**Seguridad**: no verifica `X-Hub-Signature-256`; declarado como TODO en el
generador.

---

## wf_ingesta

| | |
|---|---|
| Propósito | del binario a `movimientos` con productos resueltos |
| Trigger | Execute Workflow (`inputSource: passthrough`) |
| Entrada | `{evento, sesion_id, chat_id}` |
| Externas | Telegram `getFile`+descarga; Graph API (2 pasos); LLM (condicional) |
| Salida | invoca `wf_enviar` (panel) y `wf_ejecutar` |

Funciones/consultas que ejecuta, en orden:
`ingesta_registrar_documento` · `ingesta_procesar_documento` ·
`ingesta_identificar_tabular` (+ `prompts_tecnicos`) ·
`ingesta_registrar_formato_inferido` · `ingesta_cargar_tabular` ·
`match_resolver_documento` · `ingesta_resumen_documento` ·
`carga_registrar_fallo` (dos veces, por rama de error) · `carga_evaluar`.

**Lógica en nodos** `[CONFIRMADO]`:
- `DetectarSeparador` (JS): cuenta `, ; \t |` en la primera línea. Es detección
  de formato, decidida en un nodo.
- `AgruparFilas` (JS): tamaños de muestra **5** y **100** literales.
- `Esperar`: **11 s** literales, contra `carga_silencio_segundos = 10` en filas.
- `Decidir` (JS): mapea la respuesta de `carga_evaluar` a items. Sin decisión
  propia.

**Errores**: cinco caminos de fallo, todos confluyen en el panel; sólo la
descarga fallida pide reenvío. `retryOnFail 3` en la descarga, `2` en el LLM.

---

## wf_ejecutar

| | |
|---|---|
| Propósito | motor genérico de análisis; **no sabe qué servicio corre** |
| Trigger | Execute Workflow |
| Entrada | `{ejecucion_id, chat_id}`; si falta `ejecucion_id` toma la última en `preparando` |
| Externas | LLM (hasta 2 veces), Telegram `sendChatAction` |
| Salida | invoca `wf_enviar` (`EntregarInforme`) |

SQL: `canal_de_chat` · `ejecucion_preparar` · `informe_render` ×3 ·
`validar_cifras` ×2 · `informe_estructura_seca` · `ejecucion_cerrar`.

**Lógica en nodos** `[CONFIRMADO]`:
- La **política** «un reintento y después seco» es topología del workflow, no
  una fila.
- `RespFinal` (JS): trocea a `LIM = 3800` y **elige la plantilla por posición**
  (la de entrega va en el último trozo). Es decisión de producto en JavaScript.
- `Extraer` (JS): decide qué respuesta es inválida.

**Errores**: ver `llm.md`. Los tres caminos terminan en `Consolidar` → `Cerrar`.

---

## wf_enviar

| | |
|---|---|
| Propósito | **único punto de salida al canal** |
| Trigger | Execute Workflow |
| Entradas | `{chat_id, respuestas[]}` · `{chat_id, panel:{sesion_id, modo}}` · binario + `respuestas[].documento` |
| Externas | Telegram (`sendMessage`, `editMessageText`, `pinChatMessage`, `sendDocument`), Graph API |

SQL: `resolver_plantilla` · `canal_de_chat` · `wa_payload` · `wa_texto` ·
`carga_panel` · `carga_panel_registrar`.

**49 nodos**: 7 de envío + 7 de edición + 3 de panel-crear + 3 de panel-editar,
por la limitación del nodo de Telegram descrita en `../domains/channels.md`.

**Errores**: `EnviarTexto{k}` **sin** `onError` a propósito. Edición con
`continueErrorOutput` que degrada a mensaje nuevo salvo «not modified».

---

## wf_cron

| | |
|---|---|
| Propósito | reaper, expiración, alertas e informes periódicos |
| Trigger | Schedule cada 5 minutos |
| SQL | `SELECT mantenimiento_ciclo() AS r` |
| Salida | `wf_enviar` (`mode: each`) por notificación, `wf_ejecutar` (`mode: each`) por ejecución |

**Lógica en nodos**: cero. Los dos nodos Code sólo hacen fan-out de arrays que
Postgres ya decidió. `[CONFIRMADO]` Es el workflow más fiel a la tesis.

---

## wf_error

| | |
|---|---|
| Propósito | error workflow de los otros seis |
| Trigger | Error Trigger |
| SQL | `INSERT INTO fallas ...` (SQL literal en el nodo) + `SELECT` de admins |
| Salida | `wf_enviar` con plantilla `falla.aviso_admin` |

**Lógica en nodos** `[CONFIRMADO]`: la clasificación transitoria/permanente es
un **regex en JavaScript**
(`/timeout|ETIMEDOUT|ECONNRESET|429|rate.?limit|EAI_AGAIN|socket hang up/i`),
no una fila. Y el `INSERT` está escrito a mano en el nodo, no en una función.

**Consecuencia observada**: en esta instalación no hay usuario `admin`, así que
las 51 fallas registradas no avisaron a nadie.

---

## Clasificación

`[CONFIRMADO]` Contra la pregunta «¿cuáles son runtime, cuáles tienen lógica de
negocio y cuáles son sólo integración?»:

| Workflow | Clasificación honesta |
|---|---|
| `wf_router` | integración pura |
| `wf_cron` | integración pura |
| `wf_wa_router` | integración, **con dos divergencias de comportamiento** |
| `wf_enviar` | integración + una constante de producto (`MAX_FILAS`) duplicada con `parametros` |
| `wf_ingesta` | integración + **decisiones de formato** (delimitador, tamaños de muestra) y **una constante temporal** (11 s) |
| `wf_ejecutar` | integración + **política de reintento** + **troceado y elección de plantilla** |
| `wf_error` | integración + **clasificación de errores** + SQL literal |

`[INFERIDO]` La tesis «n8n es un runtime fijo que casi nunca se toca» se sostiene
para el 90 % del comportamiento. Lo que queda en nodos es real pero acotado, y
ya está inventariado en `agent-context/history/auditorias/2026-08.md`.

## Fotos de n8n

`[CONFIRMADO]` `workflows/fotos/*.json` son exportaciones hechas por
`bin/exportar-workflows.sh` para poder reconstruir tras perder el volumen.
`AGENTS.md` es explícito: **no son fuente de nada** y pueden estar desfasadas.
Esta auditoría las ignoró por completo; leyó los generadores.
