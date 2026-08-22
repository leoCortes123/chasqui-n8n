---
id: P-001
titulo: Dos bancos afirman el comportamiento anterior a las migraciones 075 y 076
dominio: ingesta
clasificacion: defecto
estado: aplicado
decisiones: [INGESTA-002, INGESTA-001]
decision_nueva: null
migracion: null
abierto: 2026-08-22
cerrado: 2026-08-22
---

## Evidencia

`bash bin/verificar.sh` chequeo 7, corrida del 2026-08-22:

```
carga_sin_perdida    23 | 1 | 24    silencio sin botón -> panel   esperado panel        obtenido nada
ingesta_sin_modelo   47 | 1 | 48    cierre/4 queda en error       esperado error        obtenido descartado
```

Los dos casos afirman el comportamiento **anterior** a las migraciones que ya
están aplicadas:

- `075_panel_unico_y_descartes_sin_alerta.sql` puso un advisory lock por sesión:
  mientras hay un panel en vuelo, el resto de las corridas ya no devuelve
  `panel`. `db/pruebas/carga_sin_perdida.sql:129` sigue esperando que sí.
- La misma migración separó el descarte deliberado del error. El documento
  descartado queda en `descartado`, no en `error`;
  `db/pruebas/ingesta_sin_modelo.sql:265` sigue esperando `error`.

`git log -- db/pruebas/` no registra ningún cambio desde `b20464e` (el baseline),
mientras que las 075 y 076 entraron después. Ningún invariante vigente quedó
violado: lo que quedó viejo es la afirmación del banco, no el sistema.

## Causa

`db/pruebas/carga_sin_perdida.sql:129` y `db/pruebas/ingesta_sin_modelo.sql:265`
codifican el contrato previo a la 075. Las migraciones cambiaron el
comportamiento y no arrastraron su banco en el mismo commit.

## Cambio

Los dos fallos no son el mismo problema, y el diagnóstico cambia el arreglo:

1. **`carga_sin_perdida`: la aserción está bien, el fixture quedó viejo.** La
   `075` agregó `sesiones.panel_pedido_en` y una compuerta en `carga_evaluar`
   («panel en vuelo»). El caso anterior del banco sale por una rama que anota
   `panel_pedido_en`, y el bloque *SILENCIO SIN BOTÓN* resetea `estado`, `paso`
   y `analisis_pedido_en` pero no esa marca: entra con un panel en vuelo de hace
   un segundo y se come la compuerta. `silencio sin botón → panel` **sigue
   siendo el contrato correcto** (`INGESTA-002`); cambiar el esperado a `nada`
   pondría el banco en verde afirmando menos.
2. **`ingesta_sin_modelo`: acá sí la aserción es la vieja.**
   `ingesta_cargar_tabular` llama a `ingesta_marcar_descartado` ante un archivo
   agregado. Un cierre de caja rechazado a propósito es el descarte deliberado
   que la `075` separó del error.
3. **Lo que apareció al diagnosticar, y pesa más que los dos.**
   `grep -rn "panel_pedido_en\|en_vuelo" db/pruebas/` no devolvía nada: **el
   lock no tenía un solo caso de prueba**. Las `075` y `076` existen
   exclusivamente por él —los cuatro paneles de la sesión 40, con 101 archivos—
   y ningún banco lo verificaba. Si alguien lo rompe otra vez, los siete bancos
   siguen verdes y se entera el usuario por el chat, igual que la primera vez.

Todo en `db/pruebas/`. **No hay migración**: el sistema hace lo que la decisión
dice; lo que estaba viejo era lo que lo afirmaba.

## Tareas

- [x] `carga_sin_perdida.sql`: el reset de *SILENCIO SIN BOTÓN* limpia `panel_pedido_en` y `panel_mensaje_id`; la aserción queda intacta
- [x] `ingesta_sin_modelo.sql`: esperado `error` → `descartado`, y el caso pasa a llamarse por lo que afirma
- [x] `carga_sin_perdida.sql`: tres casos nuevos del lock — en vuelo → `nada`; en vuelo vencido a los 31 s → `panel`; ya publicado → `panel`
- [x] `bash bin/pruebas.sh carga_sin_perdida ingesta_sin_modelo` — **27/27 y 48/48**
- [x] `bash bin/verificar.sh` sin violaciones
- [x] regenerar: ninguno

## R-IV

Un banco que afirma el comportamiento viejo no protege nada y entrena a ignorar
el chequeo 7; con él verde vuelve a ser cierto que una regresión de ingesta se
detecta antes de llegar al chat de un negocio.

## Cierre

`bash bin/verificar.sh` completo, 2026-08-22: **sin violaciones**, los 7 bancos
verdes. Es la primera corrida completa en verde desde la `075`.

`carga_sin_perdida` pasó de 24 casos a 27: los tres nuevos son la cobertura del
lock que las `075` y `076` nunca tuvieron.
