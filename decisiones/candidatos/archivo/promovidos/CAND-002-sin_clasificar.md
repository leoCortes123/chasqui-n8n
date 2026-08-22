---
id: CAND-002
dominio: sin_clasificar
estado: candidato
titulo: 002_contenido.sql — el comportamiento como datos
invariantes: []          # llenar a mano al promover
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: []
implementada_en: [agent-context/history/migraciones/002_contenido.sql]
afecta:
  - parametro
  - parametros   # ya no existe en db/actual/
  - plantillas   # ya no existe en db/actual/
  - plantillas_pdf   # ya no existe en db/actual/
  - prompts   # ya no existe en db/actual/
procedencia: cabecera de agent-context/history/migraciones/002_contenido.sql, commit 7eb606e 2026-08-14
---

> **Candidato, no decisión.** Extraído automáticamente el 2026-08-18.
> Nada de acá gobierna hasta que se revise, se le fije estado y se
> mueva a `decisiones/`.

## Cabecera completa, textual

```
002_contenido.sql — el comportamiento como datos.
Textos, prompts, plantillas de PDF y umbrales salen de los nodos de n8n
y viven aquí. Iterar el tono de un informe es un INSERT, no editar un nodo.

=== Plantillas de mensajes ================================================
respuestas[] de router_procesar_mensaje devuelve {plantilla, vars}.
El texto final se resuelve en Postgres, nunca en n8n.
```
