---
name: ejemplos-en-docs-ejemplos
description: "Todo archivo de ejemplo/fixture de prueba va en ejemplos/, nunca repartido en varias carpetas"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 508ccfda-cb96-47c9-b1ef-dd15af52106a
  modified: 2026-07-26T15:44:53.966Z
---

Todos los archivos de ejemplo y fixtures de prueba (CSV de ventas, XML DIAN, XLSX) viven en `ejemplos/`. La carpeta `db/fixtures/` se eliminó (2026-07-26) y su contenido se movió ahí.

**Why:** El usuario se molestó al encontrar ejemplos repartidos entre `db/fixtures/` y `ejemplos/`: quiere una sola carpeta para todos los ejemplos.

**How to apply:** Cualquier archivo de prueba nuevo (incluida la salida de `bin/gen_ventas_demo.py`, que ya escribe ahí por defecto) va a `ejemplos/`; no crear carpetas nuevas de fixtures.
