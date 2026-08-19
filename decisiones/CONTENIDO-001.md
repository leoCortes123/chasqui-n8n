---
id: CONTENIDO-001
dominio: contenido
estado: vigente
fecha: 2026-08-19
titulo: El comportamiento vive en filas, no en nodos ni en código
invariantes:
  - un texto, un botón, un umbral, un prompt o un formato se cambia con un INSERT o UPDATE en una migración, nunca editando un workflow
  - el texto final de un mensaje se resuelve en Postgres; n8n recibe el mensaje armado y lo transporta
  - agregar un servicio o un canal es un conjunto de filas; si obliga a abrir el editor de n8n, el diseño se rompió
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: [CORE-001, ROUTER-001, BASE-001]
implementada_en: [db/base/001_contenido.sql]
afecta: [resolver_plantilla, teclado_markup, parametro, plantillas, usuario_de_canal]
procedencia: cabeceras de las migraciones 002, 023, 029 y 044 (candidatos CAND-002/023/029/044), promovidas el 2026-08-19
---

## Problema medido

Antes de la 002, los textos, prompts y umbrales vivían dentro de los nodos de
n8n. Iterar el tono de un informe era editar un nodo, y cada cambio de texto
quedaba fuera de git, fuera de las migraciones y fuera de toda revisión.

El mismo patrón reapareció tres veces más:

- **023** — los botones. Un teclado definido en el workflow obliga a tocar n8n
  para agregar una opción.
- **029** — `ejecucion_preparar` llamaba a `hallazgos_generar` con el nombre
  escrito en el código: cualquier servicio nuevo con otros números habría
  recibido los hallazgos de ventas-compras. Era el bloqueador para que agregar
  un servicio no tocara n8n.
- **044** — WhatsApp. Un segundo canal con su propio router habría duplicado
  toda la máquina de estados; el canal viaja en el evento normalizado y
  `wf_enviar` lo resuelve al final desde `identidades`.

## Decisión

Todo el comportamiento observable —textos, teclados, umbrales, prompts,
servicios, formatos, intenciones— es una fila. Postgres resuelve el mensaje
completo, incluido su teclado en forma abstracta (`plantillas.teclado`), y
`teclado_markup` lo traduce a lo que espera cada canal. n8n transporta.

El despacho también es una fila: `servicios.funcion_hallazgos` dice qué función
calcula cada servicio y `ejecucion_preparar` la invoca por nombre.

Cambiar contenido sigue siendo una migración: es producto, no configuración.

## Alternativas descartadas

- **Textos en los workflows**, que es de donde se vino. Quedan fuera de git y
  de la revisión, y obligan a re-importar workflows para cambiar una palabra.
- **Un router por canal.** Duplica la máquina de estados; el segundo canal
  entra por el mismo router declarando `canal` en el evento.

## Consecuencias

La consecuencia incómoda y aceptada: un cambio de texto necesita migración y
`bin/gen_estado_sql.sh`. A cambio, `db/actual/contenido/` muestra el texto en
el diff en vez de un `INSERT` ilegible, y nada de lo que ve el usuario puede
cambiar sin quedar registrado.

Y una consecuencia para las herramientas: el despacho por filas es invisible
para cualquier analizador estático. `bin/gen_estado_sql.sh` resuelve esa arista
leyendo la tabla; sin eso, `hallazgos_generar` figura como código muerto.
