---
id: PRODUCTO-002
dominio: entrega
estado: vigente
fecha: 2026-07-26
titulo: Los resultados se entregan en el chat y en el portal, nunca como PDF
invariantes:
  - ningún resultado de análisis se entrega como archivo PDF
  - lo que no cabe en el chat va al portal, no a un adjunto
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: [PORTAL-001]
implementada_en: [agent-context/history/migraciones/047_informe_prescriptivo.sql]
afecta: [informe_render, portal_informe, portal_informes]
procedencia: instrucción del usuario, sesión del 2026-07-26; rescatada de la memoria de Claude (decisiones/candidatos/desde_memoria/entrega-portal-no-pdf.md) el 2026-08-18
---

## Problema medido

El PDF exige Gotenberg, un servicio más que levantar y mantener, y produce un
artefacto muerto: no se puede navegar, no se puede accionar sobre una
recomendación desde ahí, y queda desactualizado en el momento en que se genera.

## Decisión

El informe se entrega en el chat, y lo que no cabe se muestra en el portal, donde
cada recomendación conserva sus acciones.

## Alternativas descartadas

PDF con Gotenberg. Congelado en CORE-004 y descartado acá por razón propia: un
entregable estático rompe el ciclo detectar → recomendar → ejecutar en el último
eslabón.

## Consecuencias

Los documentos entregables que un negocio necesite mandar a un tercero (una lista
de pedido, una cotización) se analizan caso a caso: son otra cosa que un informe.
