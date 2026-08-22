---
id: CORE-003
dominio: core
estado: vigente
fecha: 2026-08-14
titulo: Una recomendación persiste después de la ejecución que la produjo
invariantes:
  - una recomendación puede evaluarse más tarde, no muere con su informe
  - el resultado de una acción se mide contra la recomendación que la originó
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: [CORE-002, CORE-004]
implementada_en: [agent-context/history/migraciones/059_recomendaciones_persistentes.sql, agent-context/history/migraciones/066_resultado.sql]
afecta: [recomendaciones_vigentes, recomendaciones_negocio, metricas_resultado]
procedencia: R-III de AGENTS.md
---

## Problema medido

Sin persistencia, cada informe reabre las mismas recomendaciones y el sistema no
puede saber si alguna sirvió. Un asistente que no recuerda lo que aconsejó no
acumula criterio: repite.

## Decisión

Las recomendaciones viven en su propia tabla, sobreviven a la ejecución, y su
resultado se mide después.

## Alternativas descartadas

Recalcularlas cada vez desde los hallazgos. Se descartó: el mismo cálculo con
datos nuevos da otra recomendación, y entonces no hay nada que evaluar.

## Consecuencias

Habilita el cooldown por regla+objeto y la comparación entre periodos. Toda
pieza que genere consejos debe escribirlos donde puedan revisarse.
