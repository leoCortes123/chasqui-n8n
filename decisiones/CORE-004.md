---
id: CORE-004
dominio: core
estado: vigente
fecha: 2026-08-14
titulo: Toda pieza nueva justifica su entrada o no entra
invariantes:
  - cada pieza aumenta el conocimiento del negocio, mejora una recomendación, o permite ejecutar/medir una decisión
  - si la justificación no se puede escribir, la pieza no entra
  - la lista de congelados no se toca sin demostrar que alimenta la capacidad de análisis
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: [CORE-001, CORE-003]
implementada_en: []
afecta: []
procedencia: R-IV de AGENTS.md; congelados en la misma tabla
---

## Problema medido

Chasqui derivaba hacia ERP: cotizador, facturación electrónica, cobros. Cada
pieza era defendible por separado y ninguna hacía que el sistema entendiera
mejor el negocio. El producto es el análisis; todo lo demás compite por el mismo
tiempo.

## Decisión

Antes de construir algo se escribe por qué mejora el análisis, la recomendación
o la ejecución. Sin esa frase, no entra.

Congelado salvo demostración: cotizador · cobro automático, suscripciones y
webhook Wompi · facturación electrónica · PDF y Gotenberg · bot público ·
pgvector · Supabase · RLS · Directus · comparativos externos Nivel 2 y 3.

## Alternativas descartadas

Mantener las piezas ERP como diferenciador comercial. Se descartó: son mesa
de entrada de cualquier software contable y no aportan criterio.

## Consecuencias

Es la pregunta con la que abre toda propuesta. Un "sería útil tener" sin
respuesta a R-IV se rechaza.
