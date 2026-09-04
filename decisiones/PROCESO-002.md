---
id: PROCESO-002
dominio: proceso
estado: vigente
fecha: 2026-08-28
titulo: El pedido es el expediente y Quipu es la prueba; la norma no se muda
invariantes:
  - todo cambio tiene un pedido en pedidos/ y un bloque en Quipu; el pedido autoriza, el bloque prueba
  - un bloque se reclama sólo si su pedido está en aprobado; reclamar sin pedido aprobado es ejecutar sin autorización
  - la evidencia de una microtarea es salida real de bin/verificar.sh, bin/pruebas.sh o bin/impacto.sh, nunca un resumen
  - las business_rule de Quipu son un espejo de sólo lectura; la norma vigente es decisiones/ y ninguna puerta de Quipu la comprueba
  - una tarea del pedido se tilda cuando su criterio de bloque quedó cumplido con evidencia enlazada
  - un bloque en verifying lo cierra un humano, y ahí su pedido pasa a aplicado
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: [PROCESO-001, DOCS-001]
implementada_en: []
afecta: [pedidos/, AGENTS.md, GUIA_TRABAJO.md, bin/hook_sesion.sh, bin/pedidos.sh, .claude/skills/pedido/SKILL.md, .mcp.json]
procedencia: auditoría del 2026-08-28 sobre QUIPU_ENTERPRISE/code/api y la base viva de Quipu (proyecto chasqui, id 1)
---

## Problema medido

El 2026-08-27 se cargó el proyecto `chasqui` en Quipu: 8 features, 43 rules,
8 bloques (P-002…P-009), 32 endpoints, 2 pantallas, 8 lecciones. Desde ese día
un cambio en curso tiene **dos registros** —el archivo de `pedidos/` y el bloque
de Quipu— y ninguna regla escrita dice cómo se relacionan. El proyecto ya pagó
caro tener registros duplicados (`ROUTER-001`, `DOCS-001`).

La pregunta era si Quipu absorbe a `pedidos/`. La auditoría del 2026-08-28 sobre
el código fuente y la base viva dice que **no puede**, y la razón es estructural,
no de madurez:

```sql
-- cambio_ambito(p_cambio_id), migración 2026_07_20_160000_create_cambio_gate
SELECT 'criterio_bloque', bac.id
FROM block_acceptance_criterion bac
JOIN block   b ON b.id = bac.block_id
JOIN feature f ON f.id = b.feature_id
WHERE f.cambio_id = p_cambio_id;
```

El ámbito de un cambio alcanza los criterios de un bloque **sólo** por
`feature.cambio_id`. Los 8 features de Chasqui tienen `cambio_id = NULL` y
`es_heredado = true` —entraron por adopción, que es como se adopta un proyecto ya
construido—. Medido en la base:

```
necesidad 0 · cambio 0 · requisito 0 · enlace 0 · firma 0
block 8 · block_acceptance_criterion 24 · block_deliverable 33
block_rule 0 · rule_implementation 0 · linea_base 0 · code_class 0
```

Es decir: **la cadena de gobierno de Quipu no puede atar ningún bloque de
Chasqui**, y no hay tool MCP que cree un bloque colgando de un cambio —
`import_project_structure` es el único camino y toma el payload del proyecto
entero, sin vínculo a un cambio. Un cambio nuevo tendría expediente sin ejecución
y ejecución sin expediente.

A eso se suma que la norma tampoco puede mudarse. `business_rule` es
`(feature_id, code, rule_type, description, formal_expr)`: **sin `estado`, sin
`supersede`, sin `superseded_by`, sin `motivo_reemplazo`, sin alternativas
descartadas, sin `procedencia`**. Una regla no se supera, se edita — y editar el
sentido de una decisión es exactamente lo que `decisiones/README.md` prohíbe. Las
43 rules cargadas ya perdieron 20 de los 63 invariantes vigentes al comprimirse,
y `PRODUCTO-001` no llegó a cargarse.

Y nada frena a un bloque que contradiga una regla: `block_rule` existe como tabla
pero **ninguna línea del código la lee ni la escribe**, y el payload de
`claim_block` (`TaskPayloadBuilder`) no incluye reglas. El agente que reclama un
bloque no ve ni un invariante.

## Decisión

Tres registros, tres responsabilidades, sin solapamiento:

| Registro | Responde | Autoridad |
|---|---|---|
| `decisiones/` | qué debe ser Chasqui | **norma** — manda sobre los otros dos |
| `pedidos/` | qué se está cambiando, por qué, y quién lo autorizó | **expediente** |
| Quipu | qué se construyó y con qué prueba | **evidencia** |

El ciclo, en once pasos, es el de `PROCESO-001` con el paso 8 partido en dos:

1-6. Sin cambios: dominio → `dominio_contexto` → `db/actual/` → `bin/impacto.sh`
→ contrastar invariantes → **reportar contradicciones antes de proponer**.
Quipu no participa: no tiene con qué.

7. La skill `/pedido` escribe `pedidos/NNN-slug.md` en `propuesto`. El humano lo
   pasa a `aprobado`. **Sigue siendo la única autorización** (`PROCESO-001`).

8a. `claim_block` sobre el bloque del pedido → `plan_microtasks`, una microtarea
    por entregable.
8b. Por cada microtarea: `start_microtask` → construir → `add_evidence` con la
    **salida real** de `bin/verificar.sh`, `bin/pruebas.sh` o `bin/impacto.sh` →
    `mark_criterion_met` → `complete_task`. La tarea del pedido se tilda **cuando
    su criterio quedó cumplido**, no antes.

9. `get_gate_status` y `bash bin/verificar.sh`. Los dos: Quipu prueba lo que se
   construyó, `verificar.sh` prueba lo que el repositorio no puede dejar de
   cumplir (lo generado, la numeración, las firmas, el baseline). Ninguno
   sustituye al otro.

10-11. Sin cambios: decisión nueva si cambió la arquitectura, mismo commit; y el
   pedido a `aplicado` cuando un humano aprueba el bloque en la Web UI
   (`POST /api/blocks/{id}/approve`, sin tool MCP a propósito).

**Un cambio que no lleva SQL ni bloque** —tocar un generador, un documento— se
queda en `pedidos/` y no entra a Quipu. No todo cambio necesita evidencia de
construcción; todo cambio necesita expediente.

## Qué se conserva de la metodología anterior, y por qué

Cuatro piezas que Quipu no tiene y que no se van a `agent-context/history/`:

| Pieza | Por qué Quipu no la cubre |
|---|---|
| **El paso 2** (`dominio_contexto` antes de leer código) | Quipu no lo pide, no lo verifica, y `claim_block` no envía las reglas |
| **La regla de contradicción y el ciclo supersede** | `business_rule` no tiene `estado` ni `supersede`: no hay forma de decir que una regla fue reemplazada |
| **`bin/verificar.sh` y `bin/impacto.sh`** | `get_existing_components` y `find_affected_screens` están ciegas: `code_class = 0`, y el indexador no entiende PL/pgSQL |
| **R-I..R-IV y la lista de congelados** | no tienen representación en el modelo de Quipu |

## Alternativas descartadas

- **Retirar `pedidos/` y que el cambio viva sólo en Quipu.** Es lo que el
  análisis sugería antes de leer `cambio_ambito()`. Se descarta por lo medido:
  la cadena de gobierno no alcanza a bloques de features heredados, no hay tool
  para crear un bloque desde un cambio, y `cambio.contexto` es texto libre sin
  puerta que lo exija. El expediente quedaría sin autoridad y sin verificación.
- **Mover los invariantes a `business_rule` y dejar `decisiones/` como archivo.**
  Se pierden `estado`, `supersede`, `motivo_reemplazo`, alternativas descartadas
  y `procedencia`. La compresión ya costó 20 invariantes de 63 y una decisión
  entera (`PRODUCTO-001`). Sin ciclo de vida, «revocar una decisión» se vuelve
  «editar una fila», que es el fallo que `decisiones/` existe para impedir.
- **Duplicar el pedido dentro de Quipu como `cambio` + `requisitos`.** Sería el
  cuarto registro describiendo lo mismo, y sin la puerta que lo ate a los
  bloques no compra nada. Se reevalúa cuando Quipu cierre Q-1 y Q-2 (abajo).
- **Esperar a que Quipu esté completo antes de usarlo.** Descartado por el mismo
  argumento que Quipu usa para su vía rápida: un sistema al que se le miente es
  peor que no tenerlo. La columna de ejecución funciona hoy y prueba lo que las
  casillas nunca probaron.

## Consecuencias

Una casilla tildada deja de ser una afirmación sin prueba: detrás de cada una hay
un criterio con evidencia real, y `mark_criterion_met` falla si no la hay. El
costo es que cerrar un cambio pasa por dos sistemas, y que las 43 rules de Quipu
hay que mantenerlas a mano como espejo — deuda registrada.

Queda abierto en Quipu, y hasta que se cierre esta decisión no cambia:

- **Q-1** — una tool que cree un bloque colgando de un `cambio`.
- **Q-2** — que `claim_block` envíe las `block_rule` del bloque en su payload.
- **Q-3** — que `block_rule` deje de ser tabla muerta y una puerta frene el
  bloque que contradice una regla.
- **Q-4** — ciclo de vida de `business_rule` (`estado`, `supersede`,
  `motivo_reemplazo`, `procedencia`), o aceptar formalmente que lo lleva
  `decisiones/`.

Con Q-1 y Q-2 cerradas, `pedidos/` se reevalúa: ahí sí Quipu podría absorber el
expediente sin perder la autorización ni el rastro.
