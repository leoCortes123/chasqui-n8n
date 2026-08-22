# pedidos/ — los cambios en curso

Un cambio de Chasqui no empieza en el código: empieza en un **pedido**. Este
directorio es el único lugar donde vive un cambio que todavía no terminó.

Existe porque el protocolo de `AGENTS.md` se ejecutaba entero dentro de una
conversación: el agente clasificaba el pedido, citaba las decisiones, proponía, y
todo eso moría con la sesión. La sesión siguiente volvía a empezar de cero y, si
el cambio había quedado a medias, nada lo decía. Un pedido es ese razonamiento
escrito a archivo, con estado, y comprobado por `bin/verificar.sh` (chequeo 10).

## Quién escribe acá

**El agente, nunca a mano.** El humano describe lo que quiere en lenguaje
natural; la skill `/pedido` hace el protocolo (dominio → decisiones vigentes →
código → impacto → contradicciones) y escribe el archivo. El humano lo lee, lo
aprueba o lo rechaza. Editar un pedido a mano no está prohibido por ningún
script, pero se salta la parte que lo hace valer: la consulta a `decisiones/`
antes de mirar el código.

## Ciclo de vida

    propuesto ──aprueba el humano──► aprobado ──se aplica y verifica──► aplicado
        │                                                                  │
        └──────────────rechaza el humano──► descartado ◄───────────────────┘
                                                 │
                              los dos terminan en pedidos/archivo/

| estado | qué significa | dónde vive |
|---|---|---|
| `propuesto` | el agente lo escribió; **nadie autorizó nada** | `pedidos/` |
| `aprobado` | el humano dijo que sí; el agente puede ejecutar | `pedidos/` |
| `aplicado` | migración aplicada, verificación verde, tareas tildadas | `pedidos/archivo/` |
| `descartado` | no se hace, con motivo escrito | `pedidos/archivo/` |

Un pedido `descartado` **no se borra**: igual que una decisión superada, su valor
es que nadie vuelva a proponer lo mismo dentro de tres meses.

## Formato

`pedidos/NNN-slug.md`, con `NNN` secuencial propio (no es el número de la
migración: un pedido puede no llevar SQL, o llevar dos).

```yaml
---
id: P-001                      # coincide con el nombre del archivo
titulo: frase que se entiende sola
dominio: ingesta               # el dominio consultado en decisiones/
clasificacion: defecto         # defecto | contenido | decision | proceso
estado: propuesto              # propuesto | aprobado | aplicado | descartado
decisiones: [INGESTA-001]      # las consultadas, no las que suenan parecido
decision_nueva: null           # id, si el cambio contradice una vigente
migracion: null                # 077_slug.sql cuando lo lleve
abierto: 2026-08-22
cerrado: null
---

## Evidencia
## Causa
## Cambio
## Tareas
- [ ] cada paso ejecutable, tildado sólo cuando corrió
## Verificación
## R-IV
```

## Qué comprueba `bin/verificar.sh` (chequeo 10)

Sin modelo, sin criterio: 

1. Estado válido, y coherente con la carpeta (`aplicado`/`descartado` viven en
   `archivo/`; `propuesto`/`aprobado`, en `pedidos/`).
2. `id` igual al nombre del archivo, sin repetirse.
3. Un pedido `aplicado` no puede tener una casilla sin tildar. Es el chequeo que
   atrapa el cambio que se dio por cerrado a medias.
4. Toda migración de `db/migraciones/` desde la `077` está nombrada por algún
   pedido. Una migración sin pedido es un cambio que entró sin pasar por el
   protocolo.
5. La migración que declara un pedido existe.

## Consultar

```bash
bash bin/pedidos.sh            # los abiertos, con su estado y qué falta
bash bin/pedidos.sh --todos    # incluye el archivo
```

Lo abierto también sale solo al arrancar una sesión (`bin/hook_sesion.sh`), que
es donde importa: un pedido a medio aplicar tiene que reaparecer sin que nadie se
acuerde de buscarlo.
