---
id: CAND-054
dominio: datos
estado: candidato
titulo: 054_inventario_declarado.sql — el stock deja de ser una suposición anónima
invariantes: []          # llenar a mano al promover
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: []
implementada_en: [agent-context/history/migraciones/054_inventario_declarado.sql]
afecta:
  - IF   # ya no existe en db/actual/
  - informe_salud_bloque
  - ingesta_cargar_inventario
  - portal_conteo_guardar
  - portal_conteos
  - portal_productos
  - recomendaciones_negocio
  - salud_negocio
  - v_balance_unidades   # ya no existe en db/actual/
  - v_rotacion_producto   # ya no existe en db/actual/
procedencia: cabecera de agent-context/history/migraciones/054_inventario_declarado.sql, commit 7eb606e 2026-08-14
---

> **Candidato, no decisión.** Extraído automáticamente el 2026-08-18.
> Nada de acá gobierna hasta que se revise, se le fije estado y se
> mueva a `decisiones/`.

## Reglas enunciadas en la cabecera

### QUÉ HACE ESTA MIGRACIÓN

1. Una tabla de conteos: el dueño (o un archivo) declara cuántas unidades
hay de un producto en una fecha.
2. `v_balance_unidades` pasa a distinguir TRES orígenes, y a decir cuál usó:

conteo    — hay un conteo y no hubo movimientos después. Stock contado.
calculado — último conteo + comprado − vendido desde esa fecha.
estimado  — no hay conteo: comprado − vendido. El comportamiento de
siempre, que se CONSERVA, pero deja de disfrazarse de dato.

3. Todo lo que deriva de un stock `estimado` queda marcado como tal: las dos
reglas lo dicen en su texto, la nota de salud lleva un asterisco con su
aclaración al pie, y `recomendaciones_negocio` publica `origen_stock` para
que cualquier consumidor futuro pueda decidir qué hacer con eso.

Lo que NO hace, a propósito: lotes, vencimientos, valuación, kardex, ajustes
por merma. Un modelo de inventario completo es un ERP; acá alcanza con saber
si el número que se le muestra al dueño lo contó alguien o lo supuso Chasqui.

=============================================================================
1. Los conteos
=============================================================================
Un conteo es un hecho fechado, no un estado: se acumulan y siempre gana el
más reciente. Así un negocio puede contar la bodega cada tanto sin que haya
que "corregir" nada, y el histórico queda para auditar de dónde salió un
número viejo.

## Cabecera completa, textual

```
054_inventario_declarado.sql — el stock deja de ser una suposición anónima.

`v_balance_unidades` (006) calcula el inventario como compradas − vendidas.
No hay stock inicial en ninguna parte, así que ese número es una estimación
desde el primer día, y sobre él se apoyan DOS de las seis reglas del informe
—"se agota" y "plata quieta"— más la nota de Inventario del índice de salud.

El síntoma ya estaba a la vista y se había parcheado en el texto: la 047
(línea 245) trata la cobertura negativa como caso propio, porque "te alcanza
para −95 días" no significa nada. Eso pasa cuando el negocio vendió más de lo
que registró comprando, que es lo normal si arrancó con mercancía en la
bodega — o sea, siempre.

El problema no es la fórmula: es que el resultado se presenta como si fuera
un hecho. Chasqui le dice a un tendero "no vuelvas a comprarlo hasta agotar
lo que tenés" sobre un stock que nadie contó. Si la cifra está mal, la
recomendación es peor que no dar ninguna.

QUÉ HACE ESTA MIGRACIÓN

1. Una tabla de conteos: el dueño (o un archivo) declara cuántas unidades
hay de un producto en una fecha.
2. `v_balance_unidades` pasa a distinguir TRES orígenes, y a decir cuál usó:

conteo    — hay un conteo y no hubo movimientos después. Stock contado.
calculado — último conteo + comprado − vendido desde esa fecha.
estimado  — no hay conteo: comprado − vendido. El comportamiento de
siempre, que se CONSERVA, pero deja de disfrazarse de dato.

3. Todo lo que deriva de un stock `estimado` queda marcado como tal: las dos
reglas lo dicen en su texto, la nota de salud lleva un asterisco con su
aclaración al pie, y `recomendaciones_negocio` publica `origen_stock` para
que cualquier consumidor futuro pueda decidir qué hacer con eso.

Lo que NO hace, a propósito: lotes, vencimientos, valuación, kardex, ajustes
por merma. Un modelo de inventario completo es un ERP; acá alcanza con saber
si el número que se le muestra al dueño lo contó alguien o lo supuso Chasqui.

=============================================================================
1. Los conteos
=============================================================================
Un conteo es un hecho fechado, no un estado: se acumulan y siempre gana el
más reciente. Así un negocio puede contar la bodega cada tanto sin que haya
que "corregir" nada, y el histórico queda para auditar de dónde salió un
número viejo.
```
