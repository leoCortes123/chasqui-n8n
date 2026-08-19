---
name: ingesta-aprende-formatos
description: "Chasqui: la ingesta tabular identifica el POS por huella de cabeceras y el LLM infiere el mapeo, no los datos"
metadata: 
  node_type: memory
  type: project
  originSessionId: 461cfd50-55b8-4a2d-8bd8-f8cee5731c22
  modified: 2026-07-25T15:24:48.209Z
---

Decisión de arquitectura del 2026-07-25 (migraciones 017–019), tomada tras corregir
la premisa: el público de Chasqui son pymes que **ya llevan números digitales** (POS,
hoja de cálculo, plataforma básica), no tiendas de barrio. Por eso la IA no está para
leer fotos de cuadernos ni notas de voz, sino para **normalizar el archivo digital que
el usuario ya tiene**.

**El LLM infiere el mapeo, nunca las cifras.** Ve solo los nombres de columna y 5 filas
de muestra, y devuelve un `mapeo` con la forma que `formatos_documento.mapeo` ya tenía.
Postgres carga todas las filas con ese mapeo. Consecuencias: cero cifras inventadas en
`movimientos`, costo independiente del tamaño del archivo (~1.3k tokens una vez),
resultado auditable y corregible a mano.

**Huella = md5 de cabeceras normalizadas y ordenadas** (`ingesta_huella`). Identifica un
layout de POS sin depender del nombre del archivo. Huella nueva → una llamada al LLM y se
persiste la fila con `origen='inferido'`; segundo archivo del mismo POS → cero tokens. El
sistema aprende formatos, que es la tesis "un formato nuevo es una fila" llevada al final.

**Why:** pedirle a un comercio que reformatee su export es pedirle algo que no sabe hacer,
y rechazar el archivo con "no se puede" pierde al cliente. Pero dejar que el LLM retipee
cifras metería números inventados en la base de negocio.

**How to apply:** al tocar la ingesta, mantener la separación — la IA decide *cómo leer*,
el SQL decide *qué se guarda*. Antes de agregar inferencia a un formato nuevo, verificar
que la compuerta de `ingesta_cargar_tabular` lo cubra: sin compuerta, un mapeo malo carga
NULLs y reporta éxito. Ver [[jsonb-build-object-literales-postgres]] y
[[proyecto-chasqui-n8n]].
