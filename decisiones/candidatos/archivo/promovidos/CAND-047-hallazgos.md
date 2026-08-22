---
id: CAND-047
dominio: hallazgos
estado: candidato
titulo: 047_informe_prescriptivo.sql — el informe deja de describir y pasa a recetar
invariantes: []          # llenar a mano al promover
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: []
implementada_en: [agent-context/history/migraciones/047_informe_prescriptivo.sql]
afecta:
  - barra_10
  - hallazgos_compras   # ya no existe en db/actual/
  - hallazgos_generar   # ya no existe en db/actual/
  - informe_estructura_seca
  - informe_render
  - informe_salud_bloque
  - recomendaciones_negocio
  - salud_negocio
  - semaforo
  - unidades_es
procedencia: cabecera de agent-context/history/migraciones/047_informe_prescriptivo.sql, commit 7eb606e 2026-08-14
---

> **Candidato, no decisión.** Extraído automáticamente el 2026-08-18.
> Nada de acá gobierna hasta que se revise, se le fije estado y se
> mueva a `decisiones/`.

## Alternativas mencionadas como descartadas

### DÓNDE SE CALCULA ESO, Y POR QUÉ NO LO HACE EL MODELO

----------------------------------------------------
El impacto en pesos, el margen resultante, el precio sugerido, la cantidad a
comprar y el proveedor más barato los calcula SQL. El modelo solo los redacta.
No es purismo: `validar_cifras` rechaza el informe si aparece un número que no
esté en los hallazgos, así que un impacto "estimado" por el modelo tumbaría la
entrega y caería al informe seco. Además las recomendaciones son REGLAS, y una
regla es una fila y una consulta, no una frase suelta que el modelo improvisa
distinto en cada corrida.

Todo lo de acá es Nivel 1: sale del historial del propio negocio, sin datos
externos. Los niveles 2 (precios oficiales tipo SIPSA) y 3 (benchmark entre
negocios anonimizados) están descritos en docs/PLAN_PRODUCCION.md; el contrato
de `recomendaciones_negocio` es el mismo, cambia de dónde sale el comparativo.

Contenido:
1. Umbrales nuevos (parámetros por negocio)
2. recomendaciones_negocio: el motor de reglas
3. salud_negocio: el semáforo de arriba del informe
4. hallazgos_generar / hallazgos_compras: los publican
5. Plantillas de layout y informe_render
6. El informe seco = la salida cruda del motor
7. Prompts

=============================================================================
1. Umbrales
=============================================================================

## Cabecera completa, textual

```
047_informe_prescriptivo.sql — el informe deja de describir y pasa a recetar.

Hasta acá el informe decía "el costo de la panela subió 10,53%". Eso es un
dato. Lo que sirve es una decisión:

La panela cuadrada 500 g te subió 10,53%.
Tu margen baja de 31,2% a 27,8%. Son unos $84.000 más al mes.
✓ Negociá con el proveedor.
✓ Comprale a Distribuidora Sur, que te la dejó a $2.900.
✓ Si no conseguís mejor precio, subí el precio de venta a $4.150.
Prioridad: alta.

DÓNDE SE CALCULA ESO, Y POR QUÉ NO LO HACE EL MODELO
----------------------------------------------------
El impacto en pesos, el margen resultante, el precio sugerido, la cantidad a
comprar y el proveedor más barato los calcula SQL. El modelo solo los redacta.
No es purismo: `validar_cifras` rechaza el informe si aparece un número que no
esté en los hallazgos, así que un impacto "estimado" por el modelo tumbaría la
entrega y caería al informe seco. Además las recomendaciones son REGLAS, y una
regla es una fila y una consulta, no una frase suelta que el modelo improvisa
distinto en cada corrida.

Todo lo de acá es Nivel 1: sale del historial del propio negocio, sin datos
externos. Los niveles 2 (precios oficiales tipo SIPSA) y 3 (benchmark entre
negocios anonimizados) están descritos en docs/PLAN_PRODUCCION.md; el contrato
de `recomendaciones_negocio` es el mismo, cambia de dónde sale el comparativo.

Contenido:
1. Umbrales nuevos (parámetros por negocio)
2. recomendaciones_negocio: el motor de reglas
3. salud_negocio: el semáforo de arriba del informe
4. hallazgos_generar / hallazgos_compras: los publican
5. Plantillas de layout y informe_render
6. El informe seco = la salida cruda del motor
7. Prompts

=============================================================================
1. Umbrales
=============================================================================
```
