---
id: P-001
titulo: Dos bancos afirman el comportamiento anterior a las migraciones 075 y 076
dominio: ingesta
clasificacion: defecto
estado: propuesto
decisiones: [INGESTA-002, INGESTA-001]
decision_nueva: null
migracion: null
abierto: 2026-08-22
cerrado: null
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

Actualizar los dos casos al contrato vigente, y sólo esos dos: el resto de los 72
casos de ambos bancos pasa. No se toca ninguna función ni ninguna fila: **no hay
migración**, porque el sistema hace lo que la decisión dice.

Al hacerlo hay que distinguir lo que la 075 quiso: el segundo panel no aparece
*porque hay uno en vuelo*, no porque el silencio deje de disparar panel. El caso
nuevo tiene que afirmar el lock, no borrar la afirmación.

## Tareas

- [ ] corregir `db/pruebas/carga_sin_perdida.sql:129` para afirmar el lock de panel (075)
- [ ] corregir `db/pruebas/ingesta_sin_modelo.sql:265`: descarte deliberado -> `descartado`
- [ ] `bash bin/pruebas.sh carga_sin_perdida ingesta_sin_modelo` — 24/24 y 48/48
- [ ] `bash bin/verificar.sh` sin violaciones
- [ ] regenerar: ninguno

## R-IV

Un banco que afirma el comportamiento viejo no protege nada y entrena a ignorar
el chequeo 7; con él verde vuelve a ser cierto que una regresión de ingesta se
detecta antes de llegar al chat de un negocio.
