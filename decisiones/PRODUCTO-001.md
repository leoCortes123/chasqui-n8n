---
id: PRODUCTO-001
dominio: producto
estado: vigente
fecha: 2026-07-25
titulo: El público son pymes que ya llevan números digitales, no tiendas de barrio sin registros
invariantes:
  - no se diseña para un negocio que no tiene registros digitales de ventas o compras
  - una funcionalidad que exija digitar movimientos a mano como flujo principal está fuera
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: [PRODUCTO-002, CORE-004]
implementada_en: []
afecta: [ingesta_cargar_tabular, ingesta_huella, formatos_documento]
procedencia: instrucción del usuario, sesión del 2026-07-25; rescatada de la memoria de Claude (decisiones/candidatos/desde_memoria/publico-objetivo-chasqui.md) el 2026-08-18
---

## Problema medido

El README describía Chasqui como "análisis por Telegram para tenderos". Un
tendero sin POS no tiene qué ingerir, y la ingesta entera —huella de cabeceras,
formatos DIAN, mapeo inferido— asume archivos exportados de un sistema.
Diseñar para quien no tiene datos habría llevado a construir captura manual, que
es otro producto.

## Decisión

El usuario objetivo ya produce ventas, compras o facturas en digital. El valor de
Chasqui es interpretar lo que ya existe, no crear el registro.

## Alternativas descartadas

Capturar movimientos por chat para negocios sin sistema. Se descartó: convierte
al producto en un cuaderno digital y contradice CORE-004 — no mejora el análisis,
crea el dato que el análisis necesita, que es otro negocio.

## Consecuencias

Corregido en `README.md` el 2026-08-18. Toda funcionalidad de captura manual
existe como excepción o complemento, nunca como el camino principal.
