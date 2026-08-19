---
id: CORE-002
dominio: core
estado: vigente
fecha: 2026-08-14
titulo: Los datos nunca se destruyen por el plan del usuario
invariantes:
  - el plan limita lectura y capacidad, jamás almacenamiento histórico
  - ningún camino de escritura puede descartar filas por plan
  - un upgrade de plan debe recuperar el pasado sin que el cliente vuelva a subir nada
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: [CORE-003]
implementada_en: [docs/historico/migraciones/053_historia_completa.sql]
afecta: [movimientos_limite_plan, mov_visibles]
procedencia: R-II de AGENTS.md; hallazgo H1 de la auditoría de agosto de 2026
---

## Problema medido

`movimientos_limite_plan()` era un `BEFORE INSERT` que devolvía `NULL` para las
filas fuera de la ventana de 3 meses del plan free. El dato no se ocultaba: no
se guardaba. Eso impedía el comparativo interanual y hacía que un upgrade no
recuperara nada — el cliente tendría que volver a subir todo.

## Decisión

El plan filtra en lectura, nunca en escritura. La 053 convirtió el límite en una
vista (`mov_visibles`) y dejó la tabla completa.

## Alternativas descartadas

Archivar las filas viejas en otra tabla al bajar de plan. Se descartó: es la
misma pérdida con un paso más, y reintroduce el riesgo en cada camino de
escritura nuevo.

## Consecuencias

Cualquier funcionalidad que proponga borrar, truncar o no insertar según el plan
contradice esta decisión.
