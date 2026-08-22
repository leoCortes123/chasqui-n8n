---
id: DOCS-001
dominio: documentacion
estado: vigente
fecha: 2026-08-22
titulo: La documentación descriptiva vive en una sola capa, agent-context/, y docs/ deja de existir
invariantes:
  - no hay dos árboles describiendo cómo funciona Chasqui; la descripción vigente vive en agent-context/
  - lo que describe el sistema no gobierna: si contradice a decisiones/ o a db/actual/, mandan ellos
  - un documento superado no se borra, se mueve a agent-context/history/, y agent-context/history/ no se cita como justificación
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: [CORE-004]
implementada_en: []
afecta: [agent-context/, agent-context/history/, ejemplos/, decisiones/README.md]
procedencia: conversación del 2026-08-22 sobre adoptar OpenSpec; el análisis previo encontró la duplicación
---

## Problema medido

El repositorio tenía **dos árboles describiendo lo mismo**: `docs/` (auditoría de
ingeniería inversa del 2026-08-19, ~2.900 líneas, **sin trackear en git**) y
`agent-context/` (2026-08-21), construido a partir del primero. La propia capa lo
tenía registrado como discrepancia sin resolver: DISC-N1 —"puede perderse o
derivar sin rastro"— y UNK-N1 —nadie sabía qué lo había generado—.

Encima de eso, `docs/` mezclaba cuatro cosas que no son documentación:

- `docs/historico/` — 74 migraciones archivadas y el prototipo de julio, que
  `bin/verificar.sh` chequeo 3 y 24 campos `implementada_en` de `decisiones/`
  referencian como rutas reales;
- `docs/ejemplos/` — fixtures que leen `bin/prueba_ciclo_vida.py:50` y
  `bin/gen_datos_prueba.py:1070`;
- `docs/GUIA_TRABAJO.md` y `docs/ROADMAP.md` — contrato y estado, no descripción;
- las guías en prosa, de las que `agent-context` ya había registrado que
  envejecieron: DISC-C5, "GUIA_TECNICA no conoce el panel de carga (071–076)".

La consecuencia medida de tener capas duplicadas no es hipotética en este
proyecto: es la misma clase de error que costó el `periodo` de
`ingesta_resumen_sesion` (`ROUTER-001`) y el ROADMAP que afirmaba un proveedor de
LLM que no era.

## Decisión

`docs/` desaparece. Cada cosa va donde su naturaleza la pone:

| Antes | Ahora | Por qué |
|---|---|---|
| `docs/historico/` | `agent-context/history/` | el porqué es un capítulo de la documentación, no un depósito aparte |
| `docs/ejemplos/` | `ejemplos/` | son fixtures que lee el código |
| `docs/GUIA_TRABAJO.md` | `GUIA_TRABAJO.md` (raíz) | es el contrato del humano, par de `AGENTS.md` |
| `docs/ROADMAP.md` | `ROADMAP.md` (raíz) | es estado abierto, no descripción |
| guías en prosa | `agent-context/{product,operations,reference,interfaces}/` | una sola capa descriptiva |
| auditoría 2026-08-19 | `agent-context/history/auditorias/2026-08-19/` | ya está absorbida por `agent-context/` |

Nada se borró: lo duplicado se archivó y lo vigente se movió.

El historial —migraciones selladas, auditorías, planes ejecutados, prototipo— **no
queda como fuente de consulta separada**: es `agent-context/history/`, el capítulo
que responde *¿por qué llegó a ser así?*, con su índice y su lugar en el mapa de
la capa. Que esté adentro no le da rango: sigue describiendo el pasado y sin
gobernar nada. Cuatro preguntas, cuatro fuentes, y la cuarta ya no vive aparte.

## Alternativas descartadas

- **Borrar el árbol sin trackear.** Eran ~2.900 líneas verificadas con etiquetas
  `[CONFIRMADO]`; `agent-context/audit/coverage.md` declara haberse apoyado en
  seis de esos archivos como detalle extenso, no copiado. Borrarlos habría dejado
  esas referencias colgando.
- **Dejar `docs/` como capa humana y `agent-context/` como capa de agentes.** Es
  la duplicación otra vez, con una excusa. El humano y el agente leen lo mismo;
  lo que cambia es por dónde entran, y para eso están `README.md` y los índices
  de `agent-context/navigation/`.
- **Dejar el histórico como directorio aparte en la raíz.** Un depósito al que
  se va "a consultar el pasado" se convierte en un segundo lugar donde buscar
  cómo funciona algo. Adentro y con índice, es un capítulo con una pregunta
  asignada; afuera, es una fuente rival.
- **Adoptar OpenSpec y dejar que `openspec/specs/` fuera la descripción.** Habría
  agregado un cuarto registro de "cómo funciona hoy". Ver `PROCESO-001`.

## Consecuencias

Una sola pregunta tiene una sola respuesta. `agent-context/` pasa de ser una capa
derivada para agentes a ser **la** documentación, y por eso su regla de rango se
vuelve más importante, no menos: describe, no gobierna.
