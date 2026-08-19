---
id: INFORME-001
dominio: informe
estado: vigente
fecha: 2026-08-19
titulo: El informe receta, declara su base, y toda cifra suya existe antes de llamar al modelo
invariantes:
  - el impacto en pesos, el precio sugerido, la cantidad a comprar y el proveedor más barato los calcula SQL; el modelo redacta
  - el informe declara sobre qué datos habla: cuántos archivos, cuántos movimientos y qué quedó fuera de la ventana del plan
  - el extractor de cifras permitidas lee los números con el mismo formato con que SQL los escribió
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: [CORE-001, CORE-003, DATOS-001, HALLAZGOS-001]
implementada_en: [docs/historico/migraciones/047_informe_prescriptivo.sql, docs/historico/migraciones/055_impacto_tipado.sql, docs/historico/migraciones/072_informe_declara_base.sql]
afecta: [validar_cifras, informe_render, informe_estructura_seca, recomendaciones_negocio]
procedencia: cabeceras de las migraciones 047, 055 y 072 (CAND-047/055/072), promovidas el 2026-08-19
---

## Problema medido

Tres cosas, todas medidas contra corridas reales:

1. **El informe describía en vez de recetar (047).** Decía qué pasó; no decía
   qué hacer, cuánto vale hacerlo ni con quién.
2. **`validar_cifras` castigaba al modelo por copiar bien (055).**
   `recomendaciones_negocio` formatea con coma decimal —"te alcanza para 142,3
   días"— y esas frases viajan dentro del JSON de hallazgos. El extractor de
   cifras permitidas usaba `'\d+(?:\.\d+)?'`, que parte "142,3" en `142` y `3`:
   el modelo citaba fielmente una cifra calculada por SQL, se la marcaba como
   inventada, se quemaba el reintento y el informe caía al seco. Pasó en las dos
   corridas reales contra el proveedor de LLM.
3. **Un informe que no se podía auditar (072).** En la segunda prueba de usuario
   entraron 63 de 101 archivos y el plan free dejó ver 196 de 380 movimientos.
   El informe hablaba de $91.506.262 cuando en la carpeta había $612.072.404, no
   declaraba nada de eso, y el semáforo daba 99/100 porque promedia sólo lo que
   pudo calcular. Todo lo visible decía que estaba bien.

## Decisión

**Las cifras son de SQL.** El impacto, el margen resultante, el precio sugerido,
la cantidad a comprar y el proveedor más barato salen de reglas —una fila y una
consulta—, no de una frase que el modelo improvisa distinto en cada corrida.

**El validador habla el mismo idioma que el formateador.** Las cifras permitidas
se extraen contemplando la coma decimal, igual que `cifra_variantes` hace del
lado del texto.

**El informe declara su base**: cuántos archivos entraron, cuántos movimientos
mira, qué quedó fuera por la ventana del plan y si no hay ventas. Ese bloque se
calcula al renderizar y no en `hallazgos_generar`, a propósito: los hallazgos
son la entrada del prompt y cada número que entra ahí engorda la lista de cifras
que el modelo puede citar.

## Alternativas descartadas

- **Dejar que el modelo estime el impacto.** `validar_cifras` tumbaría la
  entrega y caería al seco; y una recomendación sin cifra reproducible no se
  puede medir después (`CORE-003`).
- **Meter el conteo de archivos en los hallazgos.** No le sirve al modelo para
  redactar y amplía la superficie de cifras citables.

## Consecuencias

El informe seco —la salida cruda del motor de reglas— es una entrega válida y no
un modo degradado: es lo que se entrega cuando el modelo no pasa la validación.
