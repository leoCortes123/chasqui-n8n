---
id: DATOS-001
dominio: datos
estado: vigente
fecha: 2026-08-19
titulo: El stock declara de dónde salió y lo estimado no se disfraza de dato
invariantes:
  - toda unidad de stock declara su origen: conteo, calculado o estimado
  - todo lo que deriva de un stock estimado queda marcado como estimado hasta el texto que lee el usuario
  - un conteo declarado por el dueño manda sobre la estimación
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: [CORE-001, HALLAZGOS-001]
implementada_en: [docs/historico/migraciones/054_inventario_declarado.sql]
afecta: [v_balance_unidades, salud_negocio, portal_conteo_guardar, recomendaciones_negocio]
procedencia: cabecera de la migración 054 (CAND-054), promovida el 2026-08-19
---

## Problema medido

El stock se calculaba siempre como comprado − vendido. Para un negocio que
llevaba meses operando antes de usar Chasqui, ese número no es el inventario:
es la diferencia de lo que Chasqui alcanzó a ver. Y se presentaba con la misma
cara que un dato medido, así que las recomendaciones que dependían de él
—"se te agota", "tenés parado"— sonaban igual de firmes fueran ciertas o no.

## Decisión

Tres orígenes, y la vista dice cuál usó:

- `conteo` — hay un conteo declarado y no hubo movimientos después.
- `calculado` — último conteo + comprado − vendido desde esa fecha.
- `estimado` — no hay conteo: comprado − vendido. El comportamiento de siempre,
  que se conserva, pero deja de disfrazarse.

Lo estimado se marca hasta el final: las reglas lo dicen en su texto, la nota de
salud lleva su aclaración y `recomendaciones_negocio` publica `origen_stock`.
El dueño declara conteos desde el portal o por archivo.

## Alternativas descartadas

- **Exigir un conteo inicial para operar.** Es fricción antes del primer valor
  entregado; el negocio que no lo hace se queda sin análisis de inventario.
- **Ocultar el inventario cuando no hay conteo.** Se pierde una señal útil por
  no poder etiquetarla.

## Consecuencias

Un informe puede decir "según lo que vi" en vez de afirmar. Es menos vendedor y
es la única versión auditable, que es la misma razón por la que el informe
declara su base (`INFORME-001`).
