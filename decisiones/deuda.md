# Deuda descubierta

Registro de deuda encontrada mientras se construía la arquitectura de
conocimiento, y **deliberadamente no corregida**.

El patrón que este archivo existe para romper:

    agente analiza → encuentra algo viejo → decide que está mal → lo modifica
    → rompe una decisión anterior → siguiente sesión lo vuelve a cambiar

Nada de acá se toca sin una decisión explícita que lo ordene.

---

## D-001 · Diez migraciones sin cabecera que explique el porqué — CERRADA

**Cerrada:** 2026-08-18, por el baseline. Las diez quedaron absorbidas en
`db/base/` y archivadas en `agent-context/history/migraciones/`. `bin/verificar.sh`
dejó de tener la excepción "desde la 015": ahora la regla aplica a toda
migración nueva, sin asteriscos.

**Fecha:** 2026-08-18
**Evidencia:** `bin/verificar.sh` chequeo 5. Las migraciones 001, 003, 006, 007,
008, 009, 010, 011, 013 y 014 tienen cabeceras de 1 a 4 líneas; la convención
del proyecto (problema medido → reglas → alternativas descartadas) se consolidó
a partir de la 015.
**Por qué no se corrige:** son migraciones ya aplicadas. Reescribirlas viola la
regla de inmutabilidad. El chequeo se aplica desde la 015 en adelante.

## D-002 · `gen_wf_ejecutar.py` no usa `wf_lib.WF.dump()`

**Fecha:** 2026-08-18
**Evidencia:** `bin/gen_wf_ejecutar.py:406` escribe el JSON con `open(...)`
directo, mientras los otros seis generadores usan `w.dump(...)` de
`bin/wf_lib.py:57`.
**Por qué no se corrige:** uniformarlo es refactor de producto, fuera del
alcance de esta arquitectura. `bin/verificar.sh` acepta las dos formas.

## D-003 · `schema_migraciones` no guarda el hash de cada migración

**Fecha:** 2026-08-18
**Evidencia:** `bin/migrar.sh:15` crea `schema_migraciones(archivo,
aplicada_en)`. Sin hash no se puede comprobar contra la base que una migración
ya aplicada no fue modificada después.
**Por qué no se corrige:** agregar la columna es un cambio de esquema de
producto. El chequeo 3 de `bin/verificar.sh` usa git como sustituto: detecta una
migración commiteada que aparece modificada en el árbol de trabajo. Cubre el
caso real (editar una migración vieja) pero no el caso de una migración aplicada
y modificada dentro del mismo commit.

## D-004 · El banco `escenarios_generados` depende de datos cargados, no del repo — CERRADA

**Fecha:** 2026-08-18
**Evidencia:** `bash bin/verificar.sh` chequeo 6. `escenarios_generados` reporta
3 FAIL (`cargado/hay negocios generados`, `informe/la salud tiene las seis
notas`, `inventario/aparecen los tres orígenes de stock`) porque en esta base no
hay ningún negocio `PRUEBA GEN %`: el dataset se carga con
`bin/gen_datos_prueba.py` + `bin/cargar_datos_prueba.py` y es estado de entorno,
no del repositorio. Los otros 6 bancos pasan (28+105+24+48 comprobaciones).
**Cerrada:** 2026-08-19. El banco ya distingue las dos situaciones: sin dataset
cargado avisa (`cargado/dataset no cargado — correr bin/cargar_datos_prueba.py`)
y las dos comprobaciones que leían `neg` sin guarda quedaron condicionadas a que
haya negocios generados. Un banco que falla siempre en una base recién instalada
—la que se usa para probar con un usuario real— entrena a ignorar la salida de
`bin/verificar.sh`, que era el costo real de dejarlo así.

## D-005 · Dos migraciones citan una ruta que ya no existe

**Fecha:** 2026-08-18
**Evidencia:** `agent-context/history/migraciones/029_servicios_identidades_conocimiento.sql:2` y
`agent-context/history/migraciones/047_informe_prescriptivo.sql:25` citan
`docs/PLAN_PRODUCCION.md`, que se archivó en `agent-context/history/`.
**Por qué no se corrige:** son migraciones aplicadas. Editarlas para arreglar
una ruta en un comentario viola la inmutabilidad por una ganancia nula. La
referencia sigue resolviendo con un `find`.

## D-006 · Seis funciones sin llamador ni entrada conocida

**Fecha:** 2026-08-18
**Evidencia:** `db/actual/grafo.json`. Tras resolver las cuatro formas de entrada
(SQL, nodo Postgres de n8n, `EXECUTE` sobre PostgREST, trigger y despacho por
`servicios.funcion_hallazgos`), quedan sin nadie que las invoque:
`ingesta_cargar_inventario`, `ingesta_parsear_dian`, `ingesta_resumen_sesion`,
`plantilla_cuerpo`, `snapshots_backfill`, `usuario_de_telegram`.
**Por qué no se corrige:** "sin llamador" no es lo mismo que "muerta".
`snapshots_backfill` tiene nombre de utilidad de una sola vez;
`ingesta_parsear_dian` la usan `bin/cargar_datos_prueba.py` y
`bin/gen_datos_prueba.py`. Cada una necesita revisión individual antes de tocar
nada, y borrar una función viva rompe producción en silencio.

## D-007 · El nombre del modelo es entorno y vive en filas de producto

**Fecha:** 2026-08-19
**Evidencia:** `prompts.modelo` y `prompts_tecnicos.modelo` valen
`gemini-3.5-flash-lite` en los cuatro registros activos, puestos con `UPDATE`
directo porque `DEEPSEEK_BASE_URL` apunta al proxy compatible de Google. El
DEFAULT de la columna sigue siendo `deepseek-v4-flash`, y dos filas inactivas
—`prompts` id 1 y 3, versiones viejas— lo conservan. Al generar `db/base/`, el
valor de esta máquina quedó horneado en el baseline: v0 instala hoy
`gemini-3.5-flash-lite`.
**Por qué no se corrige:** hay dos salidas y las dos son decisiones de producto
que nadie tomó todavía. O el modelo es entorno y sale de una variable —lo que
obliga a que `ejecucion_preparar` lo resuelva fuera de la fila, tocando la ruta
caliente—, o es producto y el baseline lo declara, y entonces cambiar de
proveedor es una migración. Mientras no se decida, lo único falso era la
documentación: AGENTS.md decía que un `migrar.sh` en limpio deja
`deepseek-v4-flash`, y desde v0 ya no es cierto. Eso sí se corrigió.
**Riesgo mientras tanto:** un prompt nuevo insertado sin `modelo` explícito nace
con el DEFAULT, que no existe en el proxy configurado.

## D-008 · El orden de las filas del baseline depende del orden físico de la tabla

**Fecha:** 2026-08-19
**Evidencia:** `bin/gen_base.sh` vuelca el contenido con `pg_dump --data-only`,
que emite las filas en orden de `ctid`. Regenerar contra la MISMA base da un
archivo idéntico —lo comprueba la puerta de verificación— pero regenerarlo
contra una base recreada desde el propio baseline mueve filas de lugar: al
reinstalar v0 el 2026-08-19, dos plantillas cambiaron de posición sin que su
contenido cambiara. `formatos_documento` y `parametros` ya no tienen el problema
porque se generan con `ORDER BY` explícito.
**Por qué no se corrige:** `pg_dump` no acepta un orden de filas, así que
arreglarlo es escribir el volcado de las diez tablas restantes con `format()`,
como se hizo con esas dos. Se hará si el ruido en los diffs lo justifica; hoy el
determinismo que importa —dos corridas seguidas contra la misma base— se cumple.

## D-009 · `datos_incompletos` no dispara `agota` ni `cartera`

**Fecha:** 2026-08-19
**Evidencia:** con el dataset cargado, `db/pruebas/escenarios_generados.sql` da
64 pasadas y 2 fallas: `datos_incompletos/dispara agota` y
`datos_incompletos/dispara cartera` esperan `si` y obtienen `no`. Es
preexistente: el banco no se había podido correr con datos desde antes del
baseline, porque una llamada ambigua rompía `bin/cargar_datos_prueba.py`
(ver la migración 074).
**Por qué no se corrige:** hay que determinar primero cuál de los dos lados
miente — si el generador dejó de producir el faltante de stock y la factura
vencida que el escenario declara, o si las reglas `agota` y `cartera` cambiaron
de umbral y el contrato del banco quedó viejo. Tocar cualquiera de los dos sin
esa respuesta es acomodar la prueba al resultado.

## D-010 · `db/actual/` no refleja los tipos enum

**Fecha:** 2026-08-19
**Evidencia:** la migración 075 agrega el valor `descartado` a `estado_doc`.
`bin/gen_estado_sql.sh` vuelca funciones, vistas, tablas y contenido, pero no
tipos: después de regenerar, el único lugar del repo donde se lee la definición
del enum sigue siendo `db/base/000_esquema.sql`, que está congelado en el
baseline y ahora dice tres valores donde la base tiene cuatro.
**Por qué no se corrige:** el arreglo es un volcado más en `gen_estado_sql.sh`
(`db/actual/tipos/`), pero mientras `db/base/` no se rebase —y BASE-001 exige
pedirlo explícitamente— el desfase entre baseline y base viva existe igual para
todo lo que las migraciones cambian. Se corrige junto con el próximo rebase, no
antes: dos fuentes de verdad para el esquema es peor que una desactualizada.

## D-011 · El baseline sellado cita una ruta que ya no existe

**Fecha:** 2026-08-22
**Evidencia:** `db/base/000_esquema.sql:6` y el encabezado que genera
`bin/gen_base.sh:176` remiten a `docs/historico/migraciones/`. Esa ruta se movió
dos veces el 2026-08-22 (`DOCS-001`) y hoy es
`agent-context/history/migraciones/`. `gen_base.sh` ya quedó corregido; el
`.sql` no.
**Por qué no se corrige:** `db/base/` está sellado y el chequeo 3 de
`bin/verificar.sh` trata cualquier modificación suya como violación; regenerarlo
exige un rebase, que `BASE-001` obliga a pedir explícitamente. Es un comentario
en prosa: no afecta a la instalación. Se corrige solo en el próximo rebase.
