# Resumen de la auditoría

**Fecha:** 2026-08-19 · **Alcance:** repositorio completo + catálogo vivo de
Postgres + estado de la instalación + base de n8n · **Método:** jerarquía de
evidencia `comportamiento ejecutable → estado real de BD → tests → documentación
→ nombres → suposiciones`.

**No se modificó código, migraciones, configuración ni datos.** Lo único
escrito es este árbol `docs/`.

---

## 1. Componentes encontrados

**4 servicios desplegados** (+2 de perfil local): `postgres` (16.14), `n8n`
(2.31.5), `postgrest` (v12.2.12), `proxy` (caddy 2), `cloudflared`,
`registrador`. Gotenberg no está.

**12 componentes lógicos**: canal de entrada, router, presentación, carga/panel,
ingesta, matching, análisis, memoria, consulta, proactividad, portal, errores.

**En Postgres**: 1 schema (`public`), **34 tablas**, **22 vistas**, **160
funciones**, **6 enums**, **1 trigger**, **203 filas de producto en 12 tablas de
contenido**.

**En n8n**: **7 workflows**, los 7 activos, los 7 reproducibles byte a byte desde
`bin/gen_wf_*.py`.

## 2. Dominios encontrados

| Dominio | Estado |
|---|---|
| Ingestión | completo y robusto |
| Compras / Ventas / Productos | completos, como efecto de la ingesta |
| Inventario | derivado; el conteo declarado sólo entra por el portal |
| Proveedores | **duplicado**: texto libre para las reglas, `terceros` para la cartera |
| Inteligencia / Hallazgos / Informes | completos |
| Recomendaciones | completo, con ciclo de vida y medición |
| Conversación | completo |
| Canales | Telegram operativo; WhatsApp generado y no operativo |
| Conocimiento / memoria | seis mecanismos distintos, todos implementados |
| **Ejecución de acciones** | **no existe** sobre sistemas externos |

## 3. Flujos principales

| Flujo | Estado |
|---|---|
| **Ingesta** archivo → `documentos` → `movimientos` → matching → panel | implementado y probado |
| **Análisis** hallazgos SQL → LLM → render → validación → cierre → memoria | implementado; **nunca completado en esta instalación** |
| **Consulta** pregunta → intención léxica → agregados SQL → LLM → respuesta | implementado |
| **Proactividad** cron 5 min → reaper, expiración, alertas, informes periódicos | implementado; **con defecto de frecuencia confirmado** |
| **Ejecución** de una acción recomendada | **inexistente**: sólo registro + medición |

## 4. Arquitectura observada

Postgres es el sistema completo; n8n es un runtime fijo de transporte. El
comportamiento vive en filas. La tesis se sostiene para ~90 % del sistema, con
excepciones acotadas e inventariadas (troceado del informe, detección de
delimitador, clasificación de errores, constantes duplicadas).

## 5. Principales fuentes de verdad

| Categoría | Qué |
|---|---|
| Producto | las 12 tablas de contenido — se cambian **sólo por migración** |
| Normativa | `decisiones/` (18 vigentes) y `AGENTS.md` |
| Estado del código | `db/actual/`, generado desde el catálogo vivo |
| Dato original | `documentos.contenido` (bytea) — todo lo demás es reconstruible |
| Dato declarado por el dueño | `conteos_inventario`, `conocimiento`, `pagos` |
| Historia no reconstruible | `snapshots_negocio`, `ejecuciones`, `recomendaciones` |

## 6. Principales dependencias

| Dependencia | Criticidad |
|---|---|
| PostgreSQL 16 + `pgcrypto`, `pg_trgm`, `unaccent` | **total**: sin ella no hay sistema |
| n8n 2.31.5 | alta; la topología depende de límites concretos del nodo de Telegram |
| Telegram Bot API | alta: es el canal |
| Proxy LLM compatible con OpenAI | media: sin él el informe sale **seco**, no falla |
| PostgREST + Caddy | media: sólo el portal |
| Cloudflare quick tunnel | sólo desarrollo local |
| Meta Graph API | declarada, no operativa |

## 7. Funcionalidades realmente implementadas

- Ingesta multiformato (DIAN UBL 2.1, CSV/TSV/XLS/XLSX/ODS) con identificación
  por huella de cabeceras y **tres escalones** antes de gastar una llamada al
  modelo.
- Compuerta de calidad: >20 % de filas sin fecha o sin valor ⇒ 0 filas insertadas
  y un motivo que nombra la columna.
- Matching en cascada con memoria de alias.
- Panel de carga: un mensaje que se edita y se fija, con lock por sesión.
- Semáforo de salud de seis notas, donde la nota sin datos es `NULL` y no
  promedia.
- **11 reglas de negocio** con impacto en pesos, prioridad por tipo de impacto y
  textos ya redactados por SQL.
- Informe narrado por el LLM con **validación de cifras** y degradación a
  informe seco.
- Ciclo completo de recomendaciones: detectar, mostrar, persistir, cerrar con
  causa, medir el resultado.
- Snapshots diarios con los umbrales congelados.
- Consulta en lenguaje natural con intención resuelta en SQL.
- Portal sin backend, con GRANT por función y negocio desde el JWT.
- Proactividad con guardarraíles en filas.
- 7 bancos de prueba en `ROLLBACK` + E2E headless + 9 invariantes de repositorio.

## 8. Funcionalidades aparentemente incompletas

| # | Qué |
|---|---|
| 1 | **WhatsApp**: sin credenciales; además no maneja la acción `panel` y duplicaría la entrega del informe |
| 2 | **Ejecución de acciones**: no actúa sobre nada externo |
| 3 | **`ingesta_cargar_inventario`**: existe la función, el formato y la tabla, pero ninguna ruta la alcanza |
| 4 | **Cartera**: inalcanzable mientras `negocios.nit` esté vacío |
| 5 | **`snapshots_backfill`**: sin llamador |
| 6 | **Costo en pesos**: `ejecuciones.costo` nunca se escribe; el parámetro de tarifa no lo lee nadie |
| 7 | **`narrado`**: no se persiste; no se puede medir cuántos informes salen secos |
| 8 | **`cuadra`** de una factura DIAN: se calcula y se descarta |
| 9 | **Envío de documentos**: rama viva de `wf_enviar` sin ningún emisor |
| 10 | **Nota de liquidez**: se calcula, promedia, y **no se pinta** en el informe |

## 9. Contradicciones encontradas

Detalle completo en `unknowns-and-discrepancies.md`. Las que más pesan:

1. **`README.md` describe `teclado_servicios()`, que no existe** (`:175`).
2. **`README.md` dice «Los 7 workflows» y lista 6**: falta `wf_wa_router`.
3. **`README.md` dice que la próxima migración es la 075**; van 075 y 076.
4. **`docs/GUIA_TECNICA.md` no conoce el panel de carga** (nada de
   `carga_evaluar`/`carga_panel`/`descartado`): describe el modelo anterior a la
   migración 071.
5. **`HALLAZGOS-001` dice que la liquidez es una nota más; el informe no la
   pinta.**
6. **`CONTENIDO-001` exige umbrales en filas; tres están en el código**
   (`match_umbral_trgm` inexistente, el 5 % de R2, los 14 días de R7).
7. **`AGENTS.md` congela el «cotizador», que está implementado entero.**
8. **`ALERTAS-001` se cumple literalmente y produce el resultado que quería
   evitar** (57 alertas en una tarde).
9. **La tesis «nada de reglas en los nodos» tiene excepciones vivas** ya
   inventariadas y aún presentes.
10. **`cupo_tokens_mes = 0` significa «sin límite» en `ejecucion_preparar` y
    «suspendido» en `router_plan`.**

## 10. Áreas cuyo comportamiento no pudo determinarse

1. Si alguna vez se completó un análisis en esta instalación (`ejecuciones` = 0
   y n8n no guarda ejecuciones exitosas).
2. Por qué Telegram devuelve `Forbidden` (51 veces desde las 13:41).
3. Cuánto tarda `wf_ejecutar` de punta a punta.
4. Si el informe narrado pasa hoy `validar_cifras` con el modelo configurado.
5. Si los workflows desplegados coinciden nodo a nodo con el repo (coincide el
   número de nodos en los 7; no se hizo diff de contenido).
6. Si el portal funciona de punta a punta.
7. Qué produce WhatsApp con credenciales reales.
8. Por qué el escenario `datos_incompletos` no dispara `agota` ni `cartera`
   (deuda D-009).
9. Cuál es la intención con `cupo_tokens_mes = 0`.
10. Si la huella de cabeceras colisiona en la práctica.

## 11. Mediciones tomadas

`[CONFIRMADO]` Contra el negocio real (65 productos, 37.454 movimientos):

| Llamada | Tiempo |
|---|---|
| `salud_negocio(55)` | 26,9 s |
| `recomendaciones_negocio(55, true)` | 47,2 s → 123 recomendaciones |
| `hallazgos_generar(55)` | **95,6 s** → 22.175 bytes |
| `bash bin/pruebas.sh` (7 bancos) | ≈ 20 min |

Techo de una ejecución de n8n: **300 s**.

## 12. Estado de las pruebas

| Banco | Resultado |
|---|---|
| `aceptacion` | 28/28 ✔ |
| `empty_state` | 108/108 ✔ |
| `carga_sin_perdida` | 23/24 — 1 falla (contrato viejo, migración 075) |
| `ingesta_sin_modelo` | 47/48 — 1 falla (contrato viejo, migración 075) |
| `reglas_comparativas` | 4/4 ✔ |
| `router_casos` | 67 casos, sin veredicto propio (por diseño) |
| `escenarios_generados` | 10 ✔, 17 avisos (dataset no cargado) |

**Ninguna de las dos fallas es un defecto de producto**: las dos son aserciones
que la migración 075 dejó viejas.

## 13. Nivel de confianza de esta documentación

| Área | Confianza | Por qué |
|---|---|---|
| Modelo de datos | **muy alta** | leído del catálogo vivo, no de migraciones |
| Reglas de negocio | **muy alta** | transcritas del SQL, con umbrales de la tabla `parametros` |
| Router y máquina de estados | **muy alta** | 6 funciones leídas enteras + banco de 67 casos |
| Ingesta | **alta** | generador y 22 funciones leídos; el transporte no se ejecutó |
| Interfaz con el LLM | **alta** | prompts leídos de la base; ninguna llamada real se ejecutó |
| Workflows n8n | **alta** | leídos los generadores (fuente); nodos contados contra n8n |
| Portal | **alta para permisos** (catálogo), **media para comportamiento** (no se ejecutó) |
| Memoria y estado | **alta** | funciones leídas; 0 snapshots y 0 recomendaciones reales que observar |
| Rendimiento | **alta para lo medido**, nula para lo no medido |
| WhatsApp | **media** | sólo lectura de código; imposible ejecutar |
| Comportamiento bajo concurrencia | **baja** | sólo hay la evidencia indirecta de una falla registrada |

**Confianza global: alta.** La instalación estaba viva y se pudo consultar. Las
zonas grises están enumeradas y etiquetadas.

---

## Los 10 puntos que hay que entender antes de decidir nada sobre la arquitectura

### 1. El producto es SQL, no una aplicación
160 funciones, 22 vistas y 203 filas de contenido. Un cambio de comportamiento
es una migración. Esto es una fortaleza —todo es versionable y auditable— y a la
vez el techo: no hay una capa donde poner cache, y el rendimiento del producto
es el de una consulta.

### 2. El análisis no cabe en su presupuesto de tiempo
95,6 s sólo para preparar los hallazgos, sobre un techo de 300 s para toda la
ejecución (preparar + LLM + render + validar + posible reintento + cerrar, que
vuelve a correr las reglas). Con 65 productos. **Esto no es afinar una consulta:
es la razón por la que hay 0 ejecuciones y 96 documentos cargados.** Cualquier
decisión arquitectónica que no toque esto no toca el problema.

### 3. Hay un error de modelo de datos que envenena todo lo que se calcula
`productos.unidad` es un campo único. No existe factor de conversión entre la
unidad en que se compra y la unidad en que se vende. Medido: un producto que se
compra por caja a $52.801 y se vende por unidad a $3.500 produce un margen de
−1408 % y un «impacto» de $9,4 millones al mes. **Ninguna regla descarta un
margen imposible**, así que eso llega al informe, a la recomendación y a la
alerta. La nota de márgenes del semáforo salió en 2/100.

### 4. La proactividad cumple sus invariantes y aun así es una ráfaga
`alerta_max_por_corrida = 1` limita **por corrida**, y hay una corrida cada 5
minutos. Con 65 productos disparando la misma regla, el cooldown por
`(regla, clave_objeto)` no frena nada: 57 alertas registradas en una tarde. El
invariante habla de corridas porque cuando se escribió, corrida y día eran casi
lo mismo.

### 5. `ejecucion_cerrar` es el punto más cargado del sistema
Cierra la ejecución, cierra la sesión, toma el snapshot, registra las
recomendaciones (que vuelven a correr las 11 reglas) y las mide. Tres bloques
`EXCEPTION` que escriben en `fallas`. Si algo va a fallar tarde y caro, falla
aquí — y ocurre justo cuando el reloj de la ejecución está más agotado.

### 6. La memoria son seis mecanismos distintos, no uno
Archivo original, datos normalizados, snapshot diario, recomendaciones,
conocimiento declarado, y estado de sesión. **No hay memoria conversacional**:
ninguna llamada al LLM incluye turnos anteriores, y los mensajes del usuario no
se guardan. Cualquier conversación con contexto exige construirla desde cero.

### 7. El aislamiento entre empresas es por convención, no por barrera
No hay RLS (congelado). Cada función tiene que acordarse de filtrar por
`negocio_id`. En el portal el JWT lo garantiza; en el resto lo garantiza la
disciplina. Un `WHERE` olvidado en una función `SECURITY DEFINER` filtra datos
entre clientes y nada lo detecta. Con un solo negocio en la base no se ha puesto
a prueba.

### 8. Los canales pueden divergir sin que nada avise
La abstracción de canal es correcta (un router, el canal en el evento). Pero
`wf_wa_router` no maneja la acción `panel` y duplicaría la entrega del informe:
se quedó atrás cuando `wf_ejecutar` pasó a entregar por su cuenta. No hay ningún
test ni chequeo que compare los dos canales.

### 9. El LLM está bien acotado, y esa frontera es lo que hay que preservar
Recibe un JSON ya calculado, redacta, y el texto renderizado se audita contra
ese JSON. Funciona sin él (informe seco). El matiz honesto: el JSON es grande
(22 KB con listas completas de productos), así que el modelo no puede *inventar*
una cifra pero sí puede *recombinar* una legítima, y `validar_cifras` no lo ve.

### 10. Hay tres registros distintos y confundirlos es el error histórico del proyecto
`decisiones/` dice cómo debe ser. `db/actual/` dice cómo está. `db/migraciones/`
y `git log` dicen por qué llegó a serlo. `docs/historico/` no gobierna nada. Las
73 migraciones que construyeron el sistema están archivadas a propósito:
redefinían la misma función hasta 15 veces y ya costaron un fix perdido.
**Cualquier decisión arquitectónica debe empezar por `decisiones/`, no por el
código** — es el paso 2 obligatorio del protocolo de `AGENTS.md`, y va antes que
el 3.
