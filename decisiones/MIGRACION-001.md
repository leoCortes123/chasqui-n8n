---
id: MIGRACION-001
dominio: migraciones
estado: vigente
fecha: 2026-08-19
titulo: Cambiar la firma de una función obliga a borrar la anterior en la misma migración
invariantes:
  - una migración que agrega o quita un parámetro borra explícitamente la firma que reemplaza
  - ninguna sobrecarga puede dejar una llamada sin candidata única
  - una sobrecarga que sobrevive existe porque alguien la invoca, y se dice quién en la migración
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: [BASE-001]
implementada_en: [bin/verificar.sh, db/migraciones/074_identificar_tabular_sin_ambiguedad.sql]
afecta: [ingesta_identificar_tabular, hallazgos_generar, hallazgos_compras]
procedencia: auditoría del 2026-08-19; residuo de la migración 073
---

## Problema medido

`CREATE OR REPLACE FUNCTION` reemplaza una función sólo si la firma coincide. Si
cambia, crea otra y la vieja queda viva con el cuerpo anterior. La 073 le agregó
`p_muestra jsonb DEFAULT '[]'` a `ingesta_identificar_tabular` y dejó atrás la
versión de dos parámetros, la que todavía mandaba todo al modelo.

Con las dos presentes, y como la nueva trae DEFAULT en el último parámetro,
cualquier llamada de dos argumentos es ambigua:

    ERROR: function ingesta_identificar_tabular(bigint, text[]) is not unique

`bin/prueba_ciclo_vida.py`, `bin/cargar_datos_prueba.py` y `bin/gen_ventas_demo.py`
quedaron rotos desde ese día. `wf_ingesta` no lo notó porque pasa los tres
argumentos, así que producción siguió sana y el defecto vivió hasta que alguien
corrió el E2E. Además, la función muerta entró al baseline: v0 nacía con las dos.

## Decisión

Una migración que cambia la firma de una función borra la anterior con
`DROP FUNCTION` en la misma migración, y dice en la cabecera quién la llamaba.

Una sobrecarga sólo sobrevive si tiene invocador propio, y la migración lo
nombra. Es el caso de `hallazgos_generar(bigint, jsonb)` y
`hallazgos_compras(bigint, jsonb)`: `ejecucion_preparar` despacha siempre
`%I(bigint, jsonb)` leyendo `servicios.funcion_hallazgos`, así que esas dos son
la firma de producción, no un residuo — y ninguna es ambigua, porque no tienen
DEFAULT.

`bin/verificar.sh` chequeo 9 lo comprueba contra el catálogo vivo: busca pares
donde una llamada pueda resolver a dos candidatas y falla si encuentra alguno.

## Alternativas descartadas

- **Prohibir toda sobrecarga.** Mataría el despacho por
  `servicios.funcion_hallazgos`, que es la tesis del proyecto: agregar un
  servicio es un `INSERT`, no editar SQL.
- **Quitarle el DEFAULT al parámetro nuevo.** Desambigua sin borrar nada, pero
  deja viva una función de antes de la 073 que nadie mantiene y que un llamador
  futuro puede tomar por buena.
- **Confiar en el grafo de `db/actual/`.** Marcaba las dos firmas como objetos
  distintos y ninguna como muerta: `ingesta_identificar_tabular` tiene entrada
  externa por n8n, así que el análisis estático no distinguía cuál.

## Consecuencias

`db/actual/funciones/` deja de tener dos archivos para el mismo nombre salvo que
la sobrecarga sea deliberada, y en ese caso hay una decisión que la explica.
