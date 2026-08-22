---
id: CONTRACT-SALIDA-WF_ENVIAR
type: contract
status: active
provider: router / carga / ejecucion_cerrar (SQL)
consumers: [wf_enviar, DOMAIN-CANALES]
---

# Salida al canal: {chat_id, respuestas[] | panel | documento}

**Propósito**: `wf_enviar` es el ÚNICO emisor. Todo productor de mensajes
construye este item y lo despacha por sub-workflow.

## Las tres formas de entrada `[CONFIRMADO]`

| Forma | Productor | Rama en wf_enviar |
|---|---|---|
| `{chat_id, respuestas:[{plantilla,vars,teclado,editar?}]}` | router (`router_respuesta`), cierre de ejecución | texto (7 nodos enviar + 7 editar) |
| `{chat_id, panel:{sesion_id, modo}}` | `carga_evaluar` vía ingesta/cron | panel (crear/editar + fijar) |
| binario + `respuestas[].documento` | — **nadie hoy** | documento (rama sin llamador; resto del camino del PDF) |

## Semántica

- `plantilla`: clave de la tabla `plantillas`; `resolver_plantilla(clave, vars,
  teclado)` devuelve `{texto, formato, teclado}`. Clave inexistente ⇒ la clave
  misma escapada como cuerpo (mecanismo que usa `admin_reporte` para entregar
  texto libre).
- Vars escapadas con `esc_html` salvo las declaradas `crudas` en la plantilla.
- `teclado` abstracto → `teclado_markup` lo traduce a filas respetando
  `parametros.teclado_max_filas` (=6). La FORMA (nº filas) debe ser literal en
  el workflow (limitación del nodo Telegram) ⇒ regenerar con
  `bin/gen_wf_enviar.py` tras cambiar ese parámetro (DISC-D3).
- `editar:<message_id>` ⇒ `editMessageText`; fallo "not modified" se descarta;
  otro fallo degrada a mensaje nuevo.
- Panel: un mensaje fijado; `carga_panel_registrar` guarda el `message_id`
  leído de `$json.result.message_id` (el sobre completo).
- Canal real resuelto al final con `canal_de_chat(chat_id)`; WhatsApp convierte
  con `wa_texto/wa_payload` (sin editar ni fijar).

## Errores

- `EnviarTexto{k}` SIN onError: un envío fallido debe verse (hoy 51 `Forbidden`
  en `fallas`). No "arreglar" esto con continueRegularOutput.
- Callback vencido ("query too old") sí se descarta en `wf_router`.

## Tests

No hay prueba que ejecute workflows (hueco de cobertura declarado). El chequeo 1
de `bin/verificar.sh` sólo garantiza que los JSON reproducen desde generadores.
