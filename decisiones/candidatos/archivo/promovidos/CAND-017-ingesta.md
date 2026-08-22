---
id: CAND-017
dominio: ingesta
estado: candidato
titulo: 017_ingesta_tabular.sql — la ingesta tabular deja de asumir un esquema fijo
invariantes: []          # llenar a mano al promover
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: []
implementada_en: [agent-context/history/migraciones/017_ingesta_tabular.sql]
afecta:
  - ingesta_cargar_tabular
  - ingesta_fecha
  - ingesta_huella
  - ingesta_identificar_tabular   # ya no existe en db/actual/
  - ingesta_num
  - ingesta_procesar_documento
  - ingesta_registrar_documento
  - ingesta_registrar_formato_inferido
  - ingesta_resumen_documento
  - prompts_tecnicos   # ya no existe en db/actual/
procedencia: cabecera de agent-context/history/migraciones/017_ingesta_tabular.sql, commit 7eb606e 2026-08-14
---

> **Candidato, no decisión.** Extraído automáticamente el 2026-08-18.
> Nada de acá gobierna hasta que se revise, se le fije estado y se
> mueva a `decisiones/`.

## Cabecera completa, textual

```
017_ingesta_tabular.sql — la ingesta tabular deja de asumir un esquema fijo.

Qué estaba mal (verificado, no teórico):

1. Un CSV de otro POS se cargaba como éxito con TODOS los campos de negocio
en NULL. `r ->> 'fecha'` sobre una fila cuya columna se llama
"Fecha Venta" da NULL, y movimientos.fecha/cantidad/valor_* son
nullable. El documento quedaba 'parseado' y el informe corría sobre
filas vacías. Corrupción silenciosa, que es peor que rechazar.
2. `mapeo` declaraba "decimal" y "separador" y la función NUNCA los leía:
casteaba directo con ::date y ::numeric.
3. El contenedor corre con DateStyle = ISO, MDY, así que '12/03/2026'::date
da 2026-12-03 (3 de diciembre) en vez del 12 de marzo. No falla: guarda
el dato equivocado. Cualquier export dd/mm de un POS latino entraba mal.
4. Un .xlsx se rechazaba con 'formato no reconocido' porque ninguna fila de
formatos_documento lo reclamaba, aunque el nodo Extract from File de n8n
ya sabe leer xlsx/xls/ods.
5. match_resolver_documento busca raw->>'producto' o raw->>'descripcion'.
Como raw guardaba la fila original tal cual, un POS con la columna
"Descripcion" (mayúscula) dejaba todo sin resolver.

Cómo queda: la identificación del formato pasa a ser en dos fases. Por
mime/extensión se decide la CLASE (documento que Postgres parsea solo, o
tabla que n8n debe extraer primero). Para las tablas, el formato se
identifica por la HUELLA de sus cabeceras. Si la huella es nueva, n8n le
pide un mapeo al LLM, se valida y se persiste como fila: el segundo archivo
de ese mismo POS ya no gasta tokens. El LLM nunca ve las cifras, solo los
nombres de las columnas y una muestra: infiere el mapeo, no los datos.

=== 1. Clase, huella y procedencia de cada formato =========================
```
