---
id: CONTRACT-EVENTO-ROUTER
type: contract
status: active
provider: workflows de entrada (wf_router, wf_wa_router)
consumers: [DOMAIN-CONVERSACION]
---

# Evento normalizado → router_procesar_mensaje

**Propósito**: frontera n8n↔SQL. Todo mensaje o botón entra como un único JSON;
la respuesta es una lista declarativa que los workflows sólo transportan.

## Llamada (nodo Postgres de wf_router / wf_wa_router)

```sql
SELECT * FROM router_marcar_editables(router_procesar_mensaje(ev), ev);
-- wf_wa_router llama sin marcar editables: no sabe editar mensajes
```

## Entrada: `ev` (armado por el nodo `Normalizar` en JS) `[CONFIRMADO]`

```jsonc
{ "canal": "telegram" | "whatsapp",          // ROUTER-001: viaja en el evento
  "from": {"id": ..., "username": ...},
  "chat": {"id": ...},
  "texto": "...",              // message.text ‖ callback_query.data ‖ caption
  "tiene_documento": true|false,
  "callback_id": "...", "message_id": ...,   // para editar y answerCallbackQuery
  "file_id": "...", "file_name": "...", "mime": "..." }
```
Un toque de botón se normaliza al mismo campo `texto`: los callback_data SON
los comandos (`svc:`, `rec:`, `acepto:`…). Rechazo sin error: update sin secreto
o sin `from.id` ⇒ `return []` silencioso.

## Salida `[CONFIRMADO]`

```jsonc
{ "chat_id": ...,
  "respuestas": [ {"plantilla": "clave", "vars": {...}, "teclado": [...],
                    "editar": <message_id opcional>} ],
  "acciones": [ {"tipo": "enviar|ingerir|ejecutar|panel", ...} ] }
```
- El **texto final ya viene resuelto desde Postgres** (plantilla+vars); n8n no
  redacta nada (INV-007).
- `acciones[].tipo` alimenta el Switch del workflow. `panel` NO tiene salida en
  el Switch de WhatsApp (DISC-I2).
- `router_marcar_editables` añade `editar` a respuestas cuya plantilla tenga
  `reemplaza=true` si el evento fue callback.

## Precondiciones / efectos secundarios

- `usuario_de_canal` corre dentro: crea usuario, identidad y **negocio** si no
  existen (INV-022); refresca `ultima_actividad` de la sesión abierta.
- Consentimiento pendiente ⇒ casi todo devuelve plantilla
  `sistema.consentimiento` salvo informativos/menú.

## Errores y verificación

Sin sesión y sin texto reconocido ⇒ `sistema.no_entendido` (nunca excepción al
canal). Verificación: `db/pruebas/router_casos.sql`; regenerar workflows con
`python3 bin/gen_wf_router.py` si se toca el contrato.
