---
id: P-010
titulo: El desarrollo se traza en Quipu, y la documentación deja de describirlo mal
dominio: proceso
clasificacion: proceso
estado: aprobado
decisiones: [PROCESO-001, DOCS-001]
decision_nueva: PROCESO-002
migracion: null
bloque: null
abierto: 2026-08-27
cerrado: null
---

## Evidencia

El 2026-08-22 se registró a Quipu como MCP (`.mcp.json`) y se escribió la sección
§Quipu de `AGENTS.md`. El 2026-08-27 se cargó el proyecto `chasqui` (8 features,
43 rules, 8 bloques P-002…P-009, 32 endpoints, 2 pantallas, 8 lecciones), con lo
que `AGENTS.md` y `bin/hook_sesion.sh` pasaron a afirmar algo falso: que Quipu
estaba vacío y que el desarrollo iba sólo por `pedidos/`.

La auditoría del 2026-08-28 sobre `QUIPU_ENTERPRISE/code/api` y la base viva
encontró que la descripción estaba **doblemente equivocada**:

| Afirmaba `AGENTS.md` | Realidad medida |
|---|---|
| 15 tools, sólo flujo de demanda | `QuipuServer.php` registra **41 tools** en cuatro capas |
| «no existe la mitad normativa» | existe: `necesidad → cambio → requisito → cobertura`, seis puertas de cierre, firmas humanas, segregación de funciones |
| 0 bloques cargados | 8 bloques, 5 en `ready` |

Y encontró el hueco real, que no es el que el pedido suponía:

```
necesidad 0 · cambio 0 · requisito 0 · enlace 0 · firma 0
block_rule 0 · rule_implementation 0 · linea_base 0 · code_class 0
```

`cambio_ambito()` alcanza los criterios de un bloque **sólo** por
`feature.cambio_id`, y los 8 features de Chasqui son `es_heredado` con
`cambio_id = NULL`. **La cadena de gobierno de Quipu no puede atar ningún bloque
de Chasqui**, y no hay tool MCP que cree un bloque colgando de un cambio.

Además: `business_rule` no tiene `estado`, `supersede`, `motivo_reemplazo` ni
`procedencia`; las 43 rules perdieron 20 de los 63 invariantes vigentes al
comprimirse y `PRODUCTO-001` no llegó a cargarse; y `block_rule` es una tabla que
ninguna línea del código lee ni escribe, con lo que **nada frena a un bloque que
contradiga una regla**.

## Causa

No es un defecto de código. El cambio de metodología se hizo a medias: se cargó
el proyecto pero no se registró la decisión ni se actualizaron los documentos.
Y la §Quipu original se escribió leyendo la lista de tools que respondía la
instancia de ese día, no el código fuente — Quipu no usa el vocabulario de
Chasqui («decisión» es `cambio` + `requisito`, «invariante» es `business_rule`,
«contradicción» es `enlace` sospechoso), así que la mitad quedó invisible.

- `AGENTS.md:104-144` (§Quipu) — descripción falsa.
- `bin/hook_sesion.sh:85-98` — la repetía en cada sesión.
- `decisiones/` — ninguna decisión de dominio `proceso` sobre Quipu.

## Cambio

**Decisión nueva `PROCESO-002`**, `relacionada_con: [PROCESO-001, DOCS-001]`.
**No supersede a PROCESO-001**: sus cinco invariantes siguen vigentes. Fija tres
registros sin solape — `decisiones/` gobierna, `pedidos/` autoriza, Quipu prueba —
y deja escritas las cuatro piezas de la metodología anterior que se conservan
porque Quipu no las cubre, más los cuatro huecos abiertos de Quipu (Q-1…Q-4).

Se descarta retirar `pedidos/`: por lo medido arriba, el expediente quedaría sin
autoridad y sin puerta que lo ate a la ejecución.

**Archivo** de la metodología anterior en `agent-context/history/metodologia/`
(`DOCS-001`: lo superado se mueve, no se borra), y reescritura de los documentos
que la describían.

## Tareas

- [x] escribir `decisiones/PROCESO-002.md` (antes del resto, mismo commit)
- [x] archivar la metodología anterior en `agent-context/history/metodologia/`
      (`README.md`, `ciclo-solo-pedidos.md`, `quipu-dormido.md`)
- [x] reescribir `AGENTS.md` §Quipu, §Herramientas de consulta, §Protocolo y
      §pedidos
- [x] actualizar `bin/hook_sesion.sh` §Quipu
- [x] actualizar `pedidos/README.md` (reparto con Quipu, campo `bloque`)
- [x] actualizar `.claude/skills/pedido/SKILL.md` (paso 6 por Quipu, reglas)
- [x] actualizar `agent-context/README.md` (pasos 8-11 del protocolo)
- [x] actualizar `GUIA_TRABAJO.md` (§1 y §4)
- [x] actualizar la descripción de `quipu` en `.mcp.json`
- [x] regenerar: `python3 bin/gen_indice_decisiones.py`
- [x] `bin/verificar_decisiones.py`: aceptar un archivo de la raíz en `afecta`
      (sin esto una decisión de proceso no puede citar a `AGENTS.md`)
- [x] cargar en Quipu lo que falta: roles `negocio`/`analista`, `PRODUCTO-001`
      (`bin/quipu_completar.sql`) — aplicado, 45 rules, roles verificados
- [x] `bash bin/verificar.sh` — sin violaciones (2, 7 y 9 omitidos: Postgres de
      Chasqui abajo)

## Verificación

`bash bin/verificar.sh` sin violaciones. `bash bin/hook_sesion.sh` imprime el
reparto nuevo. `get_ready_blocks` sigue devolviendo 5.

## R-IV

Es un pedido de `proceso`, no de producto. Su justificación es la integridad del
protocolo: hoy `AGENTS.md` y el hook de sesión describen mal la única herramienta
que puede probar que una tarea corrió de verdad, y mandan a buscar la norma donde
no está. Un agente que los lea o usa Quipu como si gobernara, o lo ignora.
