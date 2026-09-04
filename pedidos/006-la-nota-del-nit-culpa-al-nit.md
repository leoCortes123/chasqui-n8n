---
id: P-006
titulo: La nota del NIT le echa la culpa al NIT de algo que el NIT no causó
dominio: informe
clasificacion: defecto
estado: propuesto
decisiones: [INFORME-001, CONTENIDO-001, DATOS-001]
decision_nueva: null
migracion: null
abierto: 2026-08-22
cerrado: null
---

## Evidencia

Tercera prueba de usuario, 2026-08-22, negocio 168, ejecución 1. En el bloque
"Sobre qué calculé esto":

```
💡 Tus facturas las tomé todas como compras porque no tengo el NIT de tu negocio.
   Cargalo en /portal y voy a saber cuáles son ventas tuyas.
```

Las 91 facturas de esa carga son de proveedores —emisores distintos, ninguno el
negocio— y están **bien** clasificadas como compras. La nota afirma una
consecuencia que no ocurrió, y aparece tres líneas antes de un margen promedio de
-1191%, así que se lee como su explicación. No lo es (la causa real está en
P-005). El usuario que cargue el NIT no va a ver cambiar ni un número.

`INFORME-001` exige que el informe declare sobre qué datos habla. Declarar de más
—una salvedad que no aplica— es tan malo como declarar de menos: manda a revisar
donde no hay nada.

## Causa

`db/actual/funciones/informe_base_bloque.sql:66-74`:

```sql
SELECT (nullif(btrim(coalesce(n.nit, '')), '') IS NULL
        AND EXISTS (SELECT 1 FROM facturas f WHERE f.negocio_id = n.id))
  INTO v_sin_nit
```

La condición es "no tengo NIT y hay facturas", que es cierta en el caso normal de
cualquier negocio que sube facturas de proveedor sin haber cargado su NIT — o
sea, casi siempre. No mira si hay alguna factura que **podría** ser una venta
propia. La clasificación real la hace `cartera_facturar_dian.sql` comparando el
NIT del emisor contra el del negocio; sin NIT todo cae en el `ELSE` y queda
`compra`, que para 91 facturas de proveedor es exactamente lo correcto.

Además el texto está incrustado en la función, no en `plantillas`, contra
`CONTENIDO-001`. Lo mismo en `ingesta_resumen_documento.sql:24` y
`ingesta_resumen_sesion.sql:50`.

## Cambio

1. La nota sale sólo con **señal de ambigüedad**: un mismo NIT emisor concentra
   más de `nit_emisor_concentracion_pct` de las facturas del negocio —el patrón
   de quien está subiendo también las facturas que él emite—. Propuesto **30**,
   parámetro en filas.
2. El texto pasa a `plantillas` (clave `informe.nit_ambiguo`) y se reescribe para
   decir qué está en duda y qué cambia si carga el NIT, sin insinuar nada sobre
   el margen: "Hay N facturas emitidas por un mismo NIT. Si ese NIT es el tuyo
   son ventas y hoy las estoy contando como compras: cargalo en /portal y las
   reclasifico."
3. Las dos variantes de la ingesta (`ingesta_resumen_documento`,
   `ingesta_resumen_sesion`) usan la misma condición y la misma plantilla.

## Tareas

- [ ] confirmar con el humano `nit_emisor_concentracion_pct = 30`
- [ ] migración (número al aprobar): parámetro, plantilla, y las tres funciones
      que emiten la nota
- [ ] regenerar: `bash bin/gen_estado_sql.sh`
- [ ] caso en `db/pruebas/aceptacion.sql`: 91 facturas de 40 emisores ⇒ la nota
      no aparece; 91 facturas con 60% de un mismo emisor ⇒ aparece
- [ ] `bash bin/verificar.sh`

## Verificación

`informe_base_bloque(hallazgos_generar(168))` no contiene la nota del NIT.

## R-IV

Mejora el conocimiento del negocio: una salvedad que aparece siempre no informa
nada; una que aparece cuando hay ambigüedad real le pide al usuario el único dato
que Chasqui no puede deducir.
