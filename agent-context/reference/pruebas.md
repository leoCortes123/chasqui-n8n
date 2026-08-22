# Testing

## Herramientas

`[CONFIRMADO]` No hay framework de testing. Hay **tres mecanismos propios**:

| Mecanismo | Qué prueba | Cómo corre |
|---|---|---|
| **7 bancos SQL** (`db/pruebas/*.sql`) | lógica de Postgres | `bash bin/pruebas.sh` — cada banco en una transacción que termina en `ROLLBACK` |
| **E2E headless** (`bin/prueba_ciclo_vida.py`) | el ciclo de vida completo por las rutas reales | `python3 bin/prueba_ciclo_vida.py [--con-llm] [--limpiar]` |
| **Invariantes de repo** (`bin/verificar.sh`) | 10 chequeos estructurales | `bash bin/verificar.sh [--rapido]` |

`[CONFIRMADO]` Todos los bancos terminan en `ROLLBACK` y **se pueden correr
contra producción**. `router_casos.sql` además envuelve cada caso en su propio
subbloque que se revierte.

---

## Resultado de la corrida del 2026-08-19

`[CONFIRMADO]`, ejecutado durante esta auditoría (`bash bin/pruebas.sh`,
duración ≈ 20 min contra la base con 37.454 movimientos):

| Banco | Resultado |
|---|---|
| `aceptacion` | 28 / 28 ✔ |
| `empty_state` | 108 / 108 ✔ |
| `carga_sin_perdida` | 23 / 24 — **1 falla** |
| `ingesta_sin_modelo` | 47 / 48 — **1 falla** |
| `reglas_comparativas` | 4 reglas dispararon, 0 no ✔ |
| `router_casos` | 67 casos, sin veredicto propio (por diseño) |
| `escenarios_generados` | 10 pasadas, 0 fallas, **17 avisos** (dataset no cargado) |

**Las dos fallas son contratos de prueba viejos, no defectos del producto**
`[CONFIRMADO]`:

| Banco | Aserción | Esperado | Obtenido | Causa |
|---|---|---|---|---|
| `carga_sin_perdida` | `silencio sin botón -> panel` | `panel` | `nada` | migración **075** añadió el guardarraíl de «panel en vuelo» (`panel_pedido_en`); una aserción anterior ya pidió panel, así que la siguiente devuelve `nada`. El banco no se actualizó |
| `ingesta_sin_modelo` | `cierre/4 el documento queda en error` | `error` | `descartado` | migración **075** cambió el archivo agregado de `error` a `descartado`. El banco no se actualizó |

Coincide con el hallazgo A-03 de `agent-context/history/auditorias/2026-08-19/orden-de-trabajo.md`.

---

## Los 7 bancos, uno por uno

### `aceptacion.sql` (195 líneas, 28 comprobaciones)
Las pruebas de aceptación del roadmap. Arma un negocio sintético con historia y
comprueba salud, recomendaciones, snapshot, ciclo de recomendaciones, portal.
**No cubre** la corrida contra el LLM real (cuesta tokens y depende del
proveedor), declarado en su cabecera.

### `empty_state.sql` (442 líneas, 108 comprobaciones)
El negocio recién nacido. La regla que prueba **no es «que no truene»**: es la
distinción entre decir «todavía no tengo con qué» y dibujar un semáforo o una
cifra que nadie puede justificar. `salud_negocio` devolviendo `NULL` es el
resultado esperado; un `0` sería el fallo. Incluye un negocio vecino para
comprobar que no se cruzan datos.

### `carga_sin_perdida.sql` (204 líneas, 24 comprobaciones)
Banco de `INGESTA-002`. El caso central reproduce el bug medido: el usuario tocó
Analizar con archivos en vuelo, la sesión pasó a `procesando` y 38 documentos se
tiraron. Aserción: **un evento con documento SIEMPRE produce una acción
`ingerir`**, esté la sesión como esté.

### `ingesta_sin_modelo.sql` (317 líneas, 48 comprobaciones)
Banco de `INGESTA-001`. Usa las **cabeceras reales** de la segunda prueba de
usuario, no de laboratorio. El caso `cierre_caja` es el que el modelo aprendió
mal y produjo el doble conteo de $288 millones; ahora es una aserción.

### `reglas_comparativas.sql` (125 líneas)
Las 4 reglas de nivel 1 (`sin_ventas`, `proveedor_sube`, `margen_cae`,
`vs_ano_anterior`). Arma 15 meses de historia con un producto diseñado para
disparar exactamente una regla y comprueba que dispara la suya y ninguna más.
Las fechas se anclan a `current_date`, así que la prueba no caduca.

### `router_casos.sql` (173 líneas, 67 casos)
Regresión del router. Imprime salida **normalizada** (`_norm` enmascara ids y
tokens) para comparar antes/después de una migración. **Sin golden file a
propósito**: tres casos son comandos de admin cuya salida depende de toda la
base.

### `escenarios_generados.sql` (468 líneas)
No arma fixture: lee los negocios `PRUEBA GEN %` que dejó
`bin/cargar_datos_prueba.py` y comprueba que Chasqui vea lo que el manifest
declara. Sin dataset cargado da avisos, no fallas (corregido tras la deuda
D-004).

---

## Datos sintéticos

`[CONFIRMADO]` Cadena de cuatro piezas, documentada en
`agent-context/operations/datos-de-prueba.md` (577 líneas, vigente y útil):

```bash
python3 bin/gen_datos_prueba.py        # genera 12 escenarios desde el dataset UCI
python3 bin/validar_datos_prueba.py    # valida y calcula el oráculo; exit 1 si no cuadra
python3 bin/cargar_datos_prueba.py     # carga por la ruta REAL de ingesta
bash    bin/pruebas.sh escenarios_generados
```

Los 12 escenarios: `saludable`, `margen_bajo`, `costos_crecientes`,
`inventario_excesivo`, `productos_agotandose`, `proveedor_caro`,
`multiples_proveedores`, `ventas_crecientes`, `ventas_decrecientes`,
`estacional`, `datos_incompletos`, `accion_exitosa`.

`[CONFIRMADO]` Deuda abierta **D-009**: con el dataset cargado,
`datos_incompletos` no dispara `agota` ni `cartera`. Sin resolver: hay que
determinar primero si miente el generador o el contrato del banco.

## Fixtures curados

`[CONFIRMADO]` `ejemplos/` (785 archivos):

| Carpeta | Qué es |
|---|---|
| `01..05_*` | los 5 archivos numerados en el orden en que se le mandan al bot |
| `dian_oficiales/` | 13 facturas del set oficial DIAN (Invoice, notas, exportación, mandatos, moneda extranjera…) |
| `historial_6meses/` | banco de la inferencia de formatos |
| `fuente/` | dataset UCI Online Retail II |
| `generados/` | los 12 escenarios + `manifests/` |

`[CONFIRMADO]` **Riesgo declarado en el README**: los fixtures DIAN de
`ejemplos/01..03` son **sintéticos**. Los totales cuadran contra los
propios fixtures, no contra XML real de cliente.

---

## `bin/verificar.sh` — 9 invariantes de repositorio

`[CONFIRMADO]`

| # | Chequeo | Estado 2026-08-19 |
|---|---|---|
| 1 | los 7 `workflows/*.json` reproducen byte a byte desde sus generadores | ✔ |
| 2 | `db/actual/` refleja el catálogo vivo (lo regenera y compara) | ✔ |
| 3 | ninguna migración commiteada aparece modificada (usa git) | ✔ |
| 4 | numeración secuencial desde la 074 | ✔ (074–076) |
| 5 | toda migración trae cabecera ≥ 5 líneas de prosa | ✔ |
| 6 | decisiones coherentes (`bin/verificar_decisiones.py`) | ✔ 18 |
| 7 | los bancos SQL pasan | **✘ 2 bancos** |
| 8 | el baseline no trae entorno ni datos de cliente | ✔ |
| 9 | ninguna sobrecarga deja una llamada ambigua | ✔ |

`[CONFIRMADO]` El chequeo 2 **escribe**: corre `bin/gen_estado_sql.sh`, así que
regenera `db/actual/`. Esta auditoría **no lo corrió** por esa razón; los
resultados de los chequeos vienen de `agent-context/history/auditorias/2026-08-19/orden-de-trabajo.md` (misma
jornada) salvo el 7, que sí se ejecutó aquí.

`[CONFIRMADO]` El chequeo 9 nació de la migración 074: la 073 agregó un
parámetro con `DEFAULT` y `CREATE OR REPLACE` creó una **segunda** función en vez
de reemplazar. Con las dos vivas, toda llamada de dos argumentos era ambigua y
rompía los tres scripts de carga de datos de prueba. Es el origen de
`MIGRACION-001`.

---

## E2E: `bin/prueba_ciclo_vida.py` (600 líneas)

`[CONFIRMADO]` Lleva un negocio de cero a tres periodos por **las rutas reales**:

```
negocio vacío
  -> /nueva -> elegir servicio            (router_procesar_mensaje)
  -> primera factura DIAN + primer CSV    (ingesta_registrar_documento…)
  -> productos creados / alias resueltos
  -> /listo -> análisis                   (ejecucion_preparar -> ejecucion_cerrar)
  -> snapshot + recomendaciones
  -> segundo periodo, otro layout         (lo resuelve el diccionario)
  -> comparativo contra el snapshot anterior
  -> tercer periodo, fuera de la ventana free
  -> el plan crece y la historia aparece sola
```

Qué es «ruta real» y qué no, según su propio docstring:

- **Sí** lo es toda la lógica: no hay un solo `INSERT` directo en `movimientos`,
  `productos` ni `snapshots_negocio`.
- **No** lo es el transporte: la descarga de Telegram y la extracción de filas
  del CSV las hace n8n; aquí el archivo se lee de disco y se parsea con `csv`.
- El LLM queda fuera salvo con `--con-llm`. Sin él, el informe que se guarda es
  el **seco**, que es el mismo camino que toma producción cuando
  `validar_cifras` rechaza dos veces.

---

## Cobertura: qué prueba cada mecanismo

| Funcionalidad | Cubierta por | Cubierta |
|---|---|---|
| Estado vacío | `empty_state` | ✔ fuerte |
| Ciclo de vida completo | `prueba_ciclo_vida.py` | ✔ |
| Ingesta sin modelo (huella + diccionario) | `ingesta_sin_modelo` | ✔ |
| Ingesta con modelo | — | **✘** |
| Carga sin pérdida / panel | `carga_sin_perdida` | ✔ (1 aserción vieja) |
| Router | `router_casos` (67 casos, comparativo) | ✔ sin veredicto automático |
| Reglas comparativas (R7–R10) | `reglas_comparativas` | ✔ |
| Reglas de foto (R1–R6) | `aceptacion`, `escenarios_generados` | parcial |
| Regla `cartera` (R11) | `escenarios_generados` | **✘ falla, D-009** |
| Cálculos de salud | `aceptacion`, `escenarios_generados` | ✔ |
| Recomendaciones: ciclo y medición | `aceptacion` | ✔ |
| **Llamada real al LLM** | `prueba_ciclo_vida.py --con-llm` | manual, cuesta tokens |
| **Validación de cifras contra salida real del modelo** | — | **✘** |
| **Los workflows de n8n** | `verificar.sh` chequeo 1 (sólo que reproducen) | **✘ ninguna ejecución se prueba** |
| **El portal / PostgREST** | — | **✘** |
| **WhatsApp** | — | **✘** |
| **Concurrencia de ingesta** | — | **✘** (es donde apareció A-04) |
| **Rendimiento** | — | **✘** (es donde apareció A-02) |
| **Aislamiento entre negocios** | `empty_state` (un vecino) | parcial |

`[INFERIDO]` El hueco más caro: **nada prueba una ejecución de n8n**. Los siete
hallazgos críticos y altos de la auditoría del 2026-08-19 están todos en el
runtime, en la concurrencia o en el rendimiento — exactamente las tres zonas sin
cobertura.

---

## Comandos

```bash
bash bin/pruebas.sh                     # los 7 bancos
bash bin/pruebas.sh aceptacion router   # sólo esos
bash bin/pruebas.sh -v                  # con la salida completa
python3 bin/prueba_ciclo_vida.py        # E2E sin LLM
python3 bin/prueba_ciclo_vida.py --con-llm
bash bin/verificar.sh                   # 9 invariantes (REGENERA db/actual/)
bash bin/verificar.sh --rapido          # sin los bancos
bash bin/impacto.sh <función>           # quién la llama y a quién llama
```
