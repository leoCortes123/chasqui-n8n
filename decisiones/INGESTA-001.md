---
id: INGESTA-001
dominio: ingesta
estado: vigente
fecha: 2026-08-19
titulo: El formato de un archivo se reconoce por su huella y se resuelve sin el modelo siempre que se pueda
invariantes:
  - el modelo puede inferir el mapeo de columnas, jamás una cifra
  - un archivo cuya fecha o cuyo valor no se reconocen se rechaza; no se carga con campos en NULL
  - un layout ya visto no vuelve a costar una llamada al modelo
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: [CORE-001, INGESTA-002, PRODUCTO-001]
implementada_en: [docs/historico/migraciones/017_ingesta_tabular.sql, docs/historico/migraciones/073_ingesta_sin_modelo.sql]
afecta: [ingesta_identificar_tabular, ingesta_huella, ingesta_inferir_mapeo_sql, ingesta_registrar_formato_inferido, ingesta_cargar_tabular]
procedencia: cabeceras de las migraciones 017 y 073 y la memoria del 2026-07-25 (CAND-017, CAND-073, ingesta-aprende-formatos), promovidas el 2026-08-19
---

## Problema medido

Tres defectos, medidos sobre archivos reales de pruebas de usuario:

1. **Corrupción silenciosa (017).** Un CSV de otro POS se cargaba como éxito con
   todos los campos de negocio en NULL: `r ->> 'fecha'` sobre una columna que se
   llama "Fecha Venta" da NULL, y `movimientos.fecha/cantidad/valor_*` son
   nullable. El documento quedaba `parseado` y el informe corría sobre filas
   vacías. Peor que rechazar.
2. **El mapeo declaraba y nadie leía (017).** `mapeo` traía `decimal` y
   `separador` y la carga casteaba directo con `::date` y `::numeric`.
3. **Tokens quemados en un `lower()` (073).** Cada huella nueva costaba una
   llamada al modelo. Sobre las cabeceras reales de la prueba, seis de ocho
   columnas caían solas con el diccionario de sinónimos. Con cupo de 20
   peticiones diarias, diez archivos se llevaron media jornada de cuota. Y en
   una de esas inferencias el modelo aprendió MAL un formato agregado, que fue
   la causa exacta de un doble conteo.

## Decisión

El layout se identifica por **huella de cabeceras** (`ingesta_huella`: md5 de
los nombres normalizados y ordenados), no por el nombre ni la extensión del
archivo. Con esa huella:

1. **Ya conocida** → cero trabajo, cero tokens.
2. **Nueva** → `ingesta_inferir_mapeo_sql` resuelve con el diccionario de
   sinónimos y una muestra de filas: columnas, formato de fecha y separador
   decimal salen de mirar los datos, en Postgres.
3. **Sólo si ni la fecha ni el valor se reconocen** se gasta una llamada al
   modelo, que ve nombres de columna y unas filas de muestra y devuelve un
   `mapeo` — nunca cifras. Postgres carga todas las filas con ese mapeo.

Sin fecha o sin valor no hay nada que cargar: el documento se marca en error y
se dice por qué. El formato aprendido se persiste con `origen = 'inferido'`, y
por eso no entra al baseline (`BASE-001`).

## Alternativas descartadas

- **Pedirle al comercio que reformatee su export.** Es pedirle algo que no sabe
  hacer, y rechazar con "no se puede" pierde al cliente (`PRODUCTO-001`).
- **Que el modelo retipee las cifras.** Metería números inventados en la base de
  negocio, que es exactamente lo que `CORE-001` prohíbe.
- **Cargar lo que se pueda y dejar el resto en NULL.** Es el defecto 1.

## Consecuencias

El costo del modelo es independiente del tamaño del archivo y tiende a cero con
el uso: el sistema aprende formatos. Quien llame a `ingesta_identificar_tabular`
sin muestra recibe un mapeo sin formato de fecha ni separador inferidos, así que
todos los llamadores pasan las primeras 100 filas, igual que `wf_ingesta`.
