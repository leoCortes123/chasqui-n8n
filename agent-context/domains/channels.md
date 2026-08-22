---
id: DOMAIN-CANALES
type: domain
status: active
implemented_in: [bin/gen_wf_router.py, bin/gen_wf_wa_router.py, bin/gen_wf_enviar.py, db/actual/funciones/resolver_plantilla.sql, db/actual/funciones/teclado_markup.sql, db/actual/funciones/wa_payload.sql]
---

# Canales (Telegram, WhatsApp, salida)

**Propósito**: transporte. Normalizar la entrada al mismo evento para todos los
canales y ser el **único** punto de salida (`wf_enviar`).

| | |
|---|---|
| **Entry points** | `POST /webhook/<path>` Telegram (secreto embebido al generar); `GET+POST` WhatsApp; sub-workflow `wf_enviar` |
| **Salidas** | `sendMessage` / `editMessageText` / `pinChatMessage` / `sendDocument`; Graph API WhatsApp |
| **Tablas primarias** | `plantillas` (82), `identidades`, `parametros.teclado_max_filas`, `sesiones.panel_mensaje_id` |
| **Funciones primarias** | `usuario_de_canal` · `canal_de_chat` · `chat_de_usuario` · `resolver_plantilla` · `teclado_markup` · `wa_texto/wa_payload` · `carga_panel(_registrar)` |

**Contratos**: [`../contracts/salida-wf-enviar.md`](../contracts/salida-wf-enviar.md),
[`../contracts/router-evento.md`](../contracts/router-evento.md).
**Decisiones**: `CONTENIDO-001`, `ROUTER-001`.
**Invariantes**: INV-007, INV-008, INV-020.

## Por qué `wf_enviar` tiene 49 nodos `[CONFIRMADO]`

El nodo Telegram de n8n resuelve parámetros contra la descripción del nodo y
descarta lo no declarado: la **forma** del teclado (nº de filas) debe ser
literal en el workflow; sólo textos y callback_data salen de expresiones.
⇒ 7 nodos enviar + 7 editar + panel crear/editar (3+3) + ramas documento.
`MAX_FILAS=6` duplicado con `parametros.teclado_max_filas` (DISC-D3): cambiar
uno sin regenerar produce teclados inexpresables.

## Estado por canal hoy

| Canal | Estado |
|---|---|
| Telegram | operativo en entrada; salida con 51 `Forbidden` desde 2026-08-19 (A-12) |
| WhatsApp | generado y activo pero NO operativo: `WA_PHONE_NUMBER_ID` vacío ⇒ URLs sin id + filtro saltado; además su Switch no maneja acción `panel` (descarte silencioso) y duplicaría la entrega del informe (DISC-I2/I3). Sin firma `X-Hub-Signature-256` (TODO declarado) |
| Portal | DOMAIN-PORTAL |

## Detalles que importan

- `EnviarTexto{k}` va **sin** onError a propósito: un mensaje que no llega es un
  fallo visible (hoy: las 51 fallas registradas).
- Edición con degradación: "not modified" se descarta; otro error cae a mensaje nuevo.
- Panel = un solo mensaje fijado, editado en su lugar; si el mensaje muere, se
  crea uno nuevo y `panel_mensaje_id` pisa el id ("el panel se muda").
- `parse_mode: HTML` obligatorio (sin él, n8n fuerza Markdown legacy y un guion
  bajo rompe el mensaje); variables escapadas con `esc_html` salvo plantillas
  `crudas`.
- Plantillas: todas `canal='telegram'`; WhatsApp es conversión mecánica.
