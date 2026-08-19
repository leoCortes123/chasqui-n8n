# decisiones/ — la fuente normativa de Chasqui

Acá vive **qué debe ser Chasqui**: decisiones de producto y de arquitectura,
reglas de negocio, restricciones, invariantes, alternativas descartadas y las
relaciones entre unas y otras.

No es documentación descriptiva — eso es `docs/`. No es historia — eso es
`db/migraciones/` y git. Es lo que gobierna: un cambio que contradice una
decisión vigente no se hace, se discute.

## Estructura

| Ruta | Qué es |
|---|---|
| `DOMINIO-NNN.md` | Una decisión normativa. Ej. `ALERTAS-001`. |
| `candidatos/` | Material extraído automáticamente de migraciones, docs y transcripts. **No normativo.** |
| `deuda.md` | Deuda descubierta y deliberadamente no corregida. |
| `INDICE.md` | Generado. Nunca se edita a mano. |

## Ciclo de vida

    candidato  ──revisión humana──►  decisión vigente
                                           │
                              otra decisión la supersede
                                           ▼
                                    decisión superada
                                    (no se borra nunca)

Una decisión superada conserva su valor: explica qué enfoque ya se descartó y
por qué. El agente no la obedece, pero debe poder leerla para no repetir un
camino cerrado.

## Esquema

```yaml
---
id: ALERTAS-001              # DOMINIO-NNN, único
dominio: alertas
estado: vigente              # vigente | superada | descartada
fecha: 2026-08-17
titulo: Frase que se entiende sola
invariantes:                 # lo que no se puede violar sin una decisión nueva
  - ...
supersede: []                # ids que esta decisión reemplaza
superseded_by: null          # id que reemplazó a ésta
motivo_reemplazo: null       # obligatorio si estado = superada
relacionada_con: []
implementada_en: []          # migraciones / commits
afecta: []                   # rutas de db/actual/, bin/, workflows/
procedencia: ...             # de dónde salió: migración, commit, transcript+fecha
---

## Problema medido
## Decisión
## Alternativas descartadas
## Consecuencias
```

`procedencia` es obligatoria en todo lo promovido desde `candidatos/`: sin ella
no se puede distinguir un razonamiento verificado de uno inferido.
