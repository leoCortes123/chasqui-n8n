# El ciclo cuando `pedidos/` era el único registro (2026-08-22 → 2026-08-28)

**Documento archivado.** Describe el pasado; no gobierna. Vigente hoy:
`decisiones/PROCESO-002.md` y `AGENTS.md` §Ciclo de trabajo.

---

## Qué era

Entre el 2026-08-22 y el 2026-08-28, un cambio de Chasqui vivía entero en un
archivo: `pedidos/NNN-slug.md`. Ese archivo era a la vez el expediente (evidencia,
causa, decisiones consultadas), la autorización (el campo `estado`) y el rastro de
ejecución (las casillas `- [ ]`).

## El protocolo de 11 pasos

| # | Paso | Herramienta |
|---|---|---|
| 1 | identificar el o los dominios que toca la solicitud | — |
| 2 | decisiones vigentes, superadas relevantes e invariantes | `dominio_contexto(dominio)` — MCP `decisiones` |
| 3 | estado real del código, **no** `db/migraciones/` | `db/actual/INDICE.md`; `search_graph` — MCP `codigo` |
| 4 | dependencias e impacto | `bash bin/impacto.sh <función>` |
| 5 | contrastar la implementación contra los invariantes | — |
| 6 | **reportar las contradicciones antes de proponer nada** | — |
| 7 | **escribir el pedido** y esperar aprobación | skill `/pedido` → `pedidos/NNN-slug.md` |
| 8 | ejecutar, tildando cada tarea cuando corrió | — |
| 9 | verificar | `bash bin/verificar.sh` |
| 10 | registrar la decisión si cambió la arquitectura | `decisiones/`, mismo commit |
| 11 | cerrar el pedido: `aplicado` y a `pedidos/archivo/` | — |

El paso 2 iba **antes** que el 3, siempre: un agente que explora primero llega al
paso 2 con una arquitectura ya formada en la cabeza, y entonces las decisiones
sólo la confirman o le estorban.

## El ciclo de vida del pedido

    propuesto ──aprueba el humano──► aprobado ──aplicado y verificado──► aplicado
        └──────────────rechaza──────────────────► descartado

Los dos estados terminales viven en `pedidos/archivo/`. Un pedido `descartado` no
se borra: existe para que nadie reproponga lo mismo en tres meses.

## Lo que lo sostenía

- `bin/verificar.sh` **chequeo 10**: estados válidos, coherencia con la carpeta,
  ninguna tarea sin tildar en un pedido `aplicado`, ninguna migración desde la
  `077` sin un pedido que la nombre.
- `bin/hook_sesion.sh`: imprimía los pedidos abiertos al arrancar cada sesión.
- `bin/pedidos.sh`: los listaba a pedido, con el avance de sus tareas.

## Por qué dejó de alcanzar

No falló: se quedó corto en un punto medible. **Una casilla tildada es una
afirmación sin prueba.** `- [x] bash bin/verificar.sh` dice que alguien tecleó
una `x`; no dice que el comando corrió, ni con qué salida, ni sobre qué criterio.
El chequeo 10 comprueba que no queden casillas sin tildar en un pedido
`aplicado` — es decir, comprueba la *forma* del rastro, nunca su *contenido*.

Quipu cierra exactamente ese hueco: `mark_criterion_met` **falla si no hay
evidencia enlazada**, y `add_evidence` pide el output real —«pega el output, no lo
resumas»—. Por eso `PROCESO-002` no reemplaza este ciclo: le pone debajo una
columna que sí puede probar lo que el pedido afirma.

## Lo que de acá sigue vigente

Los pasos 1-7, 10 y 11 se conservan íntegros en `PROCESO-002`. Lo que cambió es
el paso 8: la ejecución dejó de ser una casilla y pasó a ser una microtarea con
evidencia. El detalle de qué se conservó y qué no está en
`decisiones/PROCESO-002.md`.
