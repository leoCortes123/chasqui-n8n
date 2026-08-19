---
id: CAND-069
dominio: hallazgos
estado: candidato
titulo: 069_cartera_liquidez.sql — la cartera deja de ser una pestaña y pasa a ser una
invariantes: []          # llenar a mano al promover
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: []
implementada_en: [docs/historico/migraciones/069_cartera_liquidez.sql]
afecta:
  - portal_factura_guardar
  - recomendacion_metrica_valor
  - recomendacion_objeto_evaluable
  - recomendaciones_negocio
  - salud_negocio
procedencia: cabecera de docs/historico/migraciones/069_cartera_liquidez.sql, commit 6bb2183 2026-08-15
---

> **Candidato, no decisión.** Extraído automáticamente el 2026-08-18.
> Nada de acá gobierna hasta que se revise, se le fije estado y se
> mueva a `decisiones/`.

## Reglas enunciadas en la cabecera

### LIQUIDEZ COMO SEXTO FRENTE

`salud_negocio` tenía cinco notas: ventas, márgenes, inventario, compras,
riesgos. Ninguna decía nada de si el negocio puede pagar. La sexta es el
porcentaje de la cartera que NO está vencida, y sigue la misma regla que las
otras cinco: **NULL si no hay datos**, y entonces no entra al promedio. Un
negocio que no factura a crédito no tiene por qué ver bajar su índice por una
nota que no le aplica.

### Y F2: EL ALTA MANUAL

Hoy `facturas` solo se llena desde XML de la DIAN, así que quien carga CSV ve
la pestaña vacía para siempre — y con F1, además, nunca recibe la
recomendación. Un formulario en el portal lo resuelve.

=============================================================================
1. Umbral
=============================================================================

## Cabecera completa, textual

```
069_cartera_liquidez.sql — la cartera deja de ser una pestaña y pasa a ser una
señal.

La auditoría la clasificó como **ERP-DRIFT**: `terceros`, `facturas`, `pagos`,
tres vistas y una pantalla, construidos en las migraciones 036-038, que
responden "¿quién me debe?" pero no la pregunta que gobierna el roadmap —
¿esto hace que Chasqui entienda mejor el negocio, recomiende algo mejor o
permita ejecutar una decisión?

La respuesta era no, y la decisión fue clara: **se justifica solo si alimenta
`recomendaciones_negocio` como señal de liquidez**. Eso es esta migración. Sin
ella, la cartera se quedaba congelada.

POR QUÉ ES `capital` Y NO OTRA COSA

Una factura vencida no es plata que se pierde: es plata que **es tuya y no
está**. Es exactamente el mismo caso que "plata quieta" —capital inmovilizado,
solo que en la calle en vez de en la bodega— así que comparte el tipo de
impacto y sus umbrales (055). Tratarla como una fuga mensual la pondría
siempre arriba de todo, que es el error que A3 vino a arreglar.

LIQUIDEZ COMO SEXTO FRENTE

`salud_negocio` tenía cinco notas: ventas, márgenes, inventario, compras,
riesgos. Ninguna decía nada de si el negocio puede pagar. La sexta es el
porcentaje de la cartera que NO está vencida, y sigue la misma regla que las
otras cinco: **NULL si no hay datos**, y entonces no entra al promedio. Un
negocio que no factura a crédito no tiene por qué ver bajar su índice por una
nota que no le aplica.

Y F2: EL ALTA MANUAL

Hoy `facturas` solo se llena desde XML de la DIAN, así que quien carga CSV ve
la pestaña vacía para siempre — y con F1, además, nunca recibe la
recomendación. Un formulario en el portal lo resuelve.

=============================================================================
1. Umbral
=============================================================================
```
