---
id: CAND-044
dominio: router
estado: candidato
titulo: 044_whatsapp.sql — WhatsApp (Cloud API) como segundo canal sobre el MISMO
invariantes: []          # llenar a mano al promover
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: []
implementada_en: [agent-context/history/migraciones/044_whatsapp.sql]
afecta:
  - canal_de_chat
  - chat_de_usuario
  - ejecucion_cerrar
  - usuario_de_canal
  - wa_payload
  - wa_texto
procedencia: cabecera de agent-context/history/migraciones/044_whatsapp.sql, commit 7eb606e 2026-08-14
---

> **Candidato, no decisión.** Extraído automáticamente el 2026-08-18.
> Nada de acá gobierna hasta que se revise, se le fije estado y se
> mueva a `decisiones/`.

## Cabecera completa, textual

```
044_whatsapp.sql — WhatsApp (Cloud API) como segundo canal sobre el MISMO
router. La identidad multicanal ya existía (029: identidades +
usuario_de_canal); lo que faltaba era que el evento pudiera declarar su canal,
que el envío sepa por dónde devolver, y la traducción de formato: HTML ->
texto de WhatsApp, teclado inline -> mensajes interactivos (botones/lista).

El wa_id de WhatsApp es el teléfono en dígitos (573001112233), así que cabe
en el mismo chat_id bigint que viaja por todos los sobres {chat_id,
respuestas[]}. Ningún workflow intermedio cambia: wf_enviar resuelve el canal
desde identidades al final del camino.

=== usuario_de_canal: el evento puede declarar su canal =====================
El router (043) llama usuario_de_canal('telegram', evento) con el canal en
duro. Redefinir el router entero para pasarle el canal sería copiar cientos
de líneas; en cambio, el evento normalizado —que arman NUESTROS workflows,
no el usuario— trae `canal` y acá pisa el argumento. Sin `canal` en el
evento, todo sigue exactamente igual que antes.
```
