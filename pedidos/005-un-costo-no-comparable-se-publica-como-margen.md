---
id: P-005
titulo: Un costo que no es comparable con el precio se publica como margen real
dominio: hallazgos
clasificacion: defecto
estado: propuesto
decisiones: [HALLAZGOS-001, DATOS-001, INFORME-001, CORE-001, CONTENIDO-001]
decision_nueva: null
migracion: null
abierto: 2026-08-22
cerrado: null
---

## Evidencia

Tercera prueba de usuario, 2026-08-22, negocio 168, ejecución 1. El informe que
recibió el usuario dice:

```
💰 Margen promedio: -1191,23 %
⚠️ Con margen bajo: 57
🔴 Márgenes ░░░░░░░░░░ 2

⚠️ Aguardiente x375ml
Lo vendés a $31.600 y te cuesta $272.391: te deja -762% de margen…
💸 Son unos $41.884.700 al mes que no estás ganando.
✓ Subilo a $320.460 y quedás en 15% de margen.
🔴 Prioridad alta
```

57 de 58 productos con margen calculable dieron negativo. Tres de esas
recomendaciones salieron además como alertas proactivas (`alertas_enviadas` 1, 2
y 3: Ron, Aguardiente, Café molido).

`HALLAZGOS-001` dice que "toda señal que entra al semáforo sale de una regla con
umbral en filas". La señal entró, la regla existe, el umbral está en filas —y aun
así el resultado es una recomendación que ningún dueño de minimercado puede
tomar en serio, con un impacto de cuarenta millones al mes. Lo que falla no es la
regla: es que nadie comprueba que sus **entradas** sean comparables entre sí.

## Causa

`db/actual/vistas/v_costo_actual_producto.sql` toma el `valor_unitario` del
último movimiento de compra; `v_precio_actual_producto`, el de la última venta;
`v_margen_producto` los resta. Ninguna de las tres sabe nada de unidades de
empaque.

Los XML DIAN de esta prueba declaran `unitCode="EA"` y `BaseQuantity=1`, pero el
precio viene por caja o bulto. Verificado sobre el XML crudo guardado en
`documentos.contenido` (movimiento 37418, factura de Distribuciones Bebidas del
Oriente):

```
Atún x160g        costo 219.450  precio 6.600    ratio 33
Café molido x250g costo 196.046  precio 11.000   ratio 18
Aguardiente x375ml costo 272.391 precio 31.600   ratio 8,6
```

Dividiendo por un empaque plausible (24 en abarrotes, 12 en licores) los márgenes
vuelven a 6-28%. O sea: el dato de compra y el de venta hablan de unidades
distintas, y Chasqui no tiene cómo saberlo — pero tampoco tiene ningún
guardarraíl que le impida publicar la resta. `v_margen_producto` no tiene piso ni
marca de confianza; `hallazgos_generar__p_negocio_id_bigint.sql:35-48` promedia
con `avg(margen_pct)`, que un solo outlier arrastra; y R3 de
`recomendaciones_negocio.sql:171-200` dispara con la sola condición
`margen_pct < v_margen_min` y multiplica la diferencia por las unidades vendidas.

No es la falta del NIT (las 91 facturas son de proveedores distintos y están bien
clasificadas como compras — ver P-006) ni la falta de inventario (el inventario
no entra en el margen).

## Cambio

Suprimir la recomendación y decir por qué, en vez de publicarla marcada:

1. `v_margen_producto` gana `confianza text` (`'ok' | 'costo_no_comparable'`) y
   `confianza_motivo`. Umbrales en `parametros` (`CONTENIDO-001`):
   - `margen_ratio_costo_max` — relación costo/precio por encima de la cual el
     costo no es comparable. Propuesto **3** (el caso real va de 8,6 a 33).
   - `margen_pct_piso` — propuesto **-100**.
   - Señal secundaria: la unidad de la compra (`movimientos.raw->>'unidad'`)
     distinta de la de la venta, o ausente en una de las dos puntas.
2. R3 de `recomendaciones_negocio` filtra `mp.confianza = 'ok'`: no se sugiere un
   precio calculado sobre un costo que no es comparable.
3. `hallazgos_generar` pasa de `avg` a mediana (`percentile_cont`) sobre las
   filas confiables, y expone `margen_no_comparables` (conteo y lista). La nota
   de márgenes del semáforo se calcula sólo con lo confiable; si no queda nada
   confiable la nota es `NULL`, que es lo que `HALLAZGOS-001` ya manda hacer.
4. Plantilla nueva `informe.costo_no_comparable`, en filas: "De N productos tomé
   el costo de una factura que viene por caja o bulto y el precio de una venta
   por unidad: no puedo calcular su margen hasta saber cuántas unidades trae el
   empaque." Sin culpar al usuario y sin prometer un margen.
5. Nada se borra: la fila sigue en la vista, marcada (`DATOS-001`).

**Fuera de alcance a propósito:** inferir el factor de empaque desde el XML.
Es un pedido de ingesta propio y bastante más caro; éste sólo impide publicar lo
que no se puede comparar.

## Tareas

- [ ] confirmar con el humano `margen_ratio_costo_max = 3` y `margen_pct_piso = -100`
- [ ] migración (número al aprobar): `v_margen_producto` con `confianza`,
      `hallazgos_generar` con mediana y `margen_no_comparables`, R3 filtrada,
      `INSERT` de los dos parámetros y de la plantilla
- [ ] regenerar: `bash bin/gen_estado_sql.sh`
- [ ] banco nuevo `db/pruebas/margen_confiable.sql`: compra 272.391 / venta
      31.600 ⇒ `confianza <> 'ok'`, R3 no dispara, la mediana la ignora, aparece
      el bloque del informe
- [ ] correr `db/pruebas/aceptacion.sql` y `db/pruebas/reglas_comparativas.sql`:
      sus márgenes sintéticos no pueden caer en la zona sospechosa
- [ ] `bash bin/verificar.sh`

## Verificación

Con los datos del negocio 168 cargados, `recomendaciones_negocio(168, true)` no
devuelve ninguna regla `margen`, y el informe trae el bloque de costo no
comparable con el conteo correcto.

## R-IV

Mejora la recomendación: una recomendación inverosímil no sólo no se ejecuta,
quema la credibilidad de todas las demás del mismo informe.
