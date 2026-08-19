---
id: HALLAZGOS-001
dominio: hallazgos
estado: vigente
fecha: 2026-08-19
titulo: El semáforo tiene seis notas y la que no se puede calcular no promedia
invariantes:
  - una nota de salud sin datos es NULL, y una nota NULL no entra al promedio ni se rellena con un valor neutro
  - la liquidez es una nota más, no una pestaña: mide qué porcentaje de la cartera no está vencida
  - toda señal que entra al semáforo sale de una regla con umbral en filas
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: [CORE-001, CORE-004, DATOS-001, INFORME-001]
implementada_en: [docs/historico/migraciones/069_cartera_liquidez.sql]
afecta: [salud_negocio, hallazgos_generar, recomendaciones_negocio]
procedencia: cabecera de la migración 069 (CAND-069), promovida el 2026-08-19
---

## Problema medido

`salud_negocio` tenía cinco notas —ventas, márgenes, inventario, compras,
riesgos— y ninguna decía si el negocio puede pagar. Al mismo tiempo, la cartera
(`terceros`, `facturas`, `pagos`, tres vistas y una pantalla, migraciones
036-038) estaba clasificada por la auditoría como deriva hacia ERP: respondía
"¿quién me debe?" pero no la pregunta que gobierna (`CORE-004`).

## Decisión

La cartera deja de ser una pestaña y se convierte en señal: la sexta nota es el
porcentaje de la cartera **no vencida**, y sigue la regla de las otras cinco —
**NULL si no hay datos**, y entonces no entra al promedio. Un negocio que no
factura a crédito no ve bajar su índice por una nota que no le aplica.

## Alternativas descartadas

- **Rellenar la nota faltante con 100 o con 50.** Las dos mienten: una premia no
  tener datos y la otra castiga por no aplicar.
- **Dejar la cartera como pantalla.** Es la deriva a ERP que `CORE-004` frena:
  la pieza se justifica porque alimenta el análisis, no porque exista.

## Consecuencias

Un índice alto sobre pocas notas no es un negocio sano: es un negocio del que se
sabe poco. Por eso el informe declara su base (`INFORME-001`) — el semáforo solo
no alcanza para detectar que faltan datos.
