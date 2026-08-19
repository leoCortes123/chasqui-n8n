---
id: CAND-050
dominio: router
estado: candidato
titulo: 050_negocio_automatico.sql — un usuario sin negocio no puede cargar nada
invariantes: []          # llenar a mano al promover
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: []
implementada_en: [docs/historico/migraciones/050_negocio_automatico.sql]
afecta:
  - usuario_de_canal
procedencia: cabecera de docs/historico/migraciones/050_negocio_automatico.sql, commit 7eb606e 2026-08-14
---

> **Candidato, no decisión.** Extraído automáticamente el 2026-08-18.
> Nada de acá gobierna hasta que se revise, se le fije estado y se
> mueva a `decisiones/`.

## Cabecera completa, textual

```
050_negocio_automatico.sql — un usuario sin negocio no puede cargar nada.

Nadie creaba la fila de `negocios`: los que había se habían insertado a mano.
Un usuario nuevo (o cualquiera después de limpiar_datos.sql) quedaba con
`usuarios.negocio_id` NULL, la sesión nacía con `negocio_id` NULL y CADA
archivo moría en el INSERT de `documentos` con "null value in column
negocio_id violates not-null constraint".

Lo peor no es el error: es que era MUDO. El nodo Registrar de wf_ingesta
aborta el workflow, el usuario manda cinco archivos, no le contesta nadie, y
cuando toca Analizar le dice "no cargaste ninguno".

El negocio ahora se crea solo, en `usuario_de_canal`, que corre en cada
mensaje entrante: eso cubre al usuario nuevo Y al viejo que quedó sin
negocio. El nombre es un marcador ('Mi negocio'); el real lo pone el dueño en
el portal. El `tipo` sigue en NULL a propósito: router_arranque_servicio lo
pregunta con botones apenas se elige un servicio.

=== usuario_de_canal (copia de la 044 + asegurar el negocio al final) =======
```
