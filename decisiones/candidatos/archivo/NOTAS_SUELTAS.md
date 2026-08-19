# Notas sueltas de la memoria de Claude — no son decisiones de fondo

Tres de las ocho notas rescatadas de la memoria no gobiernan arquitectura.
Se dejan acá para que la cola de revisión no las arrastre.

| Nota | Qué dice | Dónde corresponde |
|---|---|---|
| `logo-chasqui-figura-literal` | el logo muestra al mensajero corriendo, no una abstracción de movimiento | marca, no arquitectura. Es forma: si se rehace el logo se decide entonces |
| `ejemplos-en-docs-ejemplos` | todo fixture va en `docs/ejemplos/`, en una sola carpeta | convención de repositorio. Su lugar natural es `AGENTS.md`, no una decisión |
| `jsonb-build-object-literales-postgres` | `jsonb_build_object('k','{}')` da el string `"{}"`, no un objeto: exige `::jsonb` | lección técnica de Postgres, no de Chasqui. Ya está corregida en la migración 016 |

Las otras cinco sí se usaron: `publico-objetivo` → `PRODUCTO-001`,
`entrega-portal-no-pdf` → `PRODUCTO-002`, `portal-chasqui-postgrest` y
`default-privileges-y-cache-postgrest` → `PORTAL-001`, e
`ingesta-aprende-formatos` quedó en `por_promover/` junto a `CAND-017`.
