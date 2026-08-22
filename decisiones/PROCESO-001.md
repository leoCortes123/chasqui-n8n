---
id: PROCESO-001
dominio: proceso
estado: vigente
fecha: 2026-08-22
titulo: Un cambio empieza por un pedido escrito, no por una conversación
invariantes:
  - todo cambio arranca en un archivo de pedidos/, escrito por el agente antes de tocar código
  - ninguna migración desde la 077 entra sin un pedido que la nombre
  - un pedido en estado propuesto no autoriza nada; sólo el humano lo pasa a aprobado
  - una tarea se tilda cuando corrió, y un pedido aplicado no deja ninguna sin tildar
  - un pedido cerrado no se borra, se archiva con su estado final
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: [DOCS-001, MIGRACION-001]
implementada_en: []
afecta: [pedidos/, bin/pedidos.sh, bin/verificar.sh, bin/hook_sesion.sh, .claude/skills/pedido/SKILL.md]
procedencia: conversación del 2026-08-22, evaluando adoptar OpenSpec como metodología
---

## Problema medido

El protocolo de `AGENTS.md` (dominio → decisiones → código → impacto →
contradicciones → propuesta) se ejecutaba **entero dentro de una conversación**.
La skill `/pedido` producía un bloque `PEDIDO` bien formado y lo imprimía en el
chat. Al cerrar la sesión desaparecían la clasificación, las decisiones citadas,
la causa y la lista de verificación; la sesión siguiente arrancaba de cero y no
tenía forma de saber que había un cambio a medio aplicar.

Nada en el repositorio podía responder dos preguntas que se hacen todos los días:

1. ¿qué cambio está en curso ahora mismo?
2. ¿este cambio se terminó, o se dio por terminado?

`bin/verificar.sh` —que es el juez del repositorio, con nueve chequeos sin
modelo— no tenía ninguno sobre el proceso, porque no había artefacto que revisar.

## Decisión

El pedido es la unidad de cambio y **es un archivo**: `pedidos/NNN-slug.md`, con
frontmatter (id, dominio, clasificación, estado, decisiones consultadas, decisión
nueva, migración) y cuerpo (evidencia, causa, cambio, tareas tildables,
verificación, R-IV). Lo escribe la skill `/pedido` al final del protocolo; el
humano aprueba cambiando el estado.

    propuesto ──aprueba el humano──► aprobado ──aplicado y verificado──► aplicado
        └──────────────rechaza──────────────────► descartado

Tres piezas lo sostienen, y ninguna es un recordatorio:

- `bin/verificar.sh` **chequeo 10**: estados válidos, coherencia con la carpeta,
  ninguna tarea sin tildar en un pedido `aplicado`, y ninguna migración desde la
  `077` sin pedido que la nombre.
- `bin/hook_sesion.sh` imprime los pedidos abiertos al arrancar cualquier sesión.
- `bin/pedidos.sh` los lista a pedido, con el avance de sus tareas.

La escritura y la modificación de un pedido pasan por el agente. El humano
consulta, aprueba y rechaza; no redacta el artefacto. La razón es la misma por la
que existe el protocolo: quien escribe el pedido tiene que haber consultado
`decisiones/` **antes** de mirar el código, y esa consulta es trabajo de agente.

## Alternativas descartadas

- **Adoptar OpenSpec** (`openspec/changes/` + `specs/`). Aporta las tres cosas
  que faltaban —estado persistente, tareas tildadas, verificación de cierre— pero
  trae un `specs/` que sería un cuarto registro describiendo comportamiento, en un
  proyecto que ya pagó caro tener registros duplicados (`ROUTER-001`, `DOCS-001`).
  Además, sus artefactos no pasan por `bin/verificar.sh`: para que gobernaran
  había que escribir igual el chequeo 10. Se descartó el paquete y se conservó la
  idea. Su formato de requisito (`SHALL` + escenario) tampoco carga `procedencia`,
  `supersede` ni alternativas descartadas, que es lo que hace útil a `decisiones/`.
- **Dejar el pedido en el chat y confiar en el historial de la conversación.** Es
  lo que había. No sobrevive a cerrar la terminal ni es auditable.
- **Numerar el pedido con el número de su migración.** Se rompe con los cambios
  que no llevan SQL —tocar un generador de workflow, este mismo pedido— y con los
  que llevan dos. El vínculo es un campo, no el nombre del archivo.

## Consecuencias

`git log` deja de ser el único lugar donde consta por qué entró un cambio, y pasa
a haber un artefacto anterior al commit. El costo es un archivo por cambio; el
piso lo pone el chequeo 10, que hace que saltárselo sea una violación y no un
olvido.
