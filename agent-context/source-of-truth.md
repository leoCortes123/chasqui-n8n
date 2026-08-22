# Fuente de verdad — qué archivo manda sobre qué

Un agente debe saber qué fuente tiene autoridad sobre cada tipo de información.
Si dos fuentes discrepan, manda la de mayor rango en esta tabla.

## Jerarquía de autoridad

| Información | Fuente canónica | Rango | No usar para eso |
|---|---|---|---|
| Reglas del proyecto, restricciones, congelados | `AGENTS.md` | **normativo** | — |
| Qué debe ser el sistema (decisiones) | `decisiones/*.md` + `decisiones/INDICE.md` | **normativo** | esta capa |
| Deuda deliberadamente no corregida | `decisiones/deuda.md` (D-001…D-010) | normativo-operativa | — |
| Cómo está implementado algo HOY (SQL) | `db/actual/` (`INDICE.md`, `funciones/`, `vistas/`, `tablas/`, `contenido/`, `grafo.json`) | **realidad** (generado) | `db/migraciones/`, `db/base/000_esquema.sql` (congelado en v0), `agent-context/history/` |
| Cómo están construidos los workflows | `bin/gen_wf_*.py` + `bin/wf_lib.py` (fuente) → `workflows/wf_*.json` (generado) | realidad | `workflows/fotos/*.json` (**no son fuente de nada**) |
| Contenido de producto (textos, umbrales, prompts) | 12 tablas volcadas en `db/actual/contenido/`; entran por migración | realidad | editar un workflow o un nodo |
| Esquema completo de instalación nueva | `db/base/000..002` (Chasqui v0, sellado) | baseline | leerlo como esquema vigente (D-010: enums desfasados) |
| Cambios desde v0 | `db/migraciones/074+` (aplicadas, inmutables) | historia reciente | saber "cómo funciona hoy" |
| Por qué quedó como quedó | `agent-context/history/` (capítulo de esta capa: migraciones selladas, auditorías, planes ejecutados) | descriptiva del pasado | el presente, y cualquier justificación vigente |
| Descripción prosaica del diseño | `agent-context/operations/guia-tecnica.md`, `agent-context/product/guia-funcional.md` | descriptiva; manda `db/actual/` si discrepan | comportamiento exacto actual (GUIA_TECNICA no conoce 071–076) |
| Descripción del sistema en prosa | `agent-context/` (esta capa: mapas, contratos, `product/`, `operations/`, `reference/`, `interfaces/`) | derivada; describe, no gobierna | reemplazar a `decisiones/` o al código |
| Qué cambio está en curso | `pedidos/` + `bash bin/pedidos.sh` | operativa | saber cómo funciona algo: un pedido es intención, no realidad |
| Auditoría inversa del 2026-08-19 | `agent-context/history/auditorias/2026-08-19/` | archivo; ya absorbida por esta capa | cualquier cosa vigente |
| Metadatos machine-readable | `agent-context/generated/*.json` (por `bin/gen_agent_context.py`) | derivada de `db/actual/` + `workflows/` | — |

## Mapa por tipo de pregunta

```text
¿Qué es Chasqui y qué NO es?        → AGENTS.md · decisiones/CORE-004, PRODUCTO-001
¿Qué decisiones debo respetar?      → decisiones/INDICE.md · agent-context/invariants/
¿Dónde está implementado X?         → agent-context/navigation/by-component.md
                                        · db/actual/INDICE.md · bin/impacto.sh <fn>
¿Quién llama a / usa Y?             → bin/impacto.sh <fn> [--tabla] · db/actual/grafo.json
                                        · generated/symbols.json, dependencies.json
¿Qué contrato puedo romper?         → agent-context/contracts/
¿Cómo se verifica un cambio?        → AGENTS.md §comandos · agent-context/reference/pruebas.md
                                        · agent-context/navigation/by-task.md §verificar
¿Qué está roto o sin resolver?      → decisiones/deuda.md · audit/discrepancies.md
                                        · ROADMAP.md §abierto
¿Qué se está cambiando ahora?       → bash bin/pedidos.sh · pedidos/README.md
¿Cómo se pide un cambio?            → skill /pedido → pedidos/NNN-slug.md (PROCESO-001)
¿Qué no se puede saber del repo?    → audit/unknowns.md
```

## Advertencias de rango frecuentes

- `db/migraciones/` sólo tiene 3 archivos (074–076). Las 73 que construyeron el
  sistema están archivadas y **no gobiernan ni describen el presente**.
- No existe `docs/`: se disolvió el 2026-08-22 (`DOCS-001`). Lo vivo está en esta
  capa, lo archivado en `agent-context/history/`, los fixtures en `ejemplos/`.
- Todo lo que dice "Generado — no editar a mano" se regenera:
  `bin/gen_estado_sql.sh`, `bin/gen_wf_*.py`, `bin/gen_indice_decisiones.py`,
  `bin/gen_agent_context.py`.
- `bin/verificar.sh` chequeo 2 **escribe**: regenera `db/actual/`. No es sólo lectura.
