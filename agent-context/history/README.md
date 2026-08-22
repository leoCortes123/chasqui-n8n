# history — cómo llegó Chasqui hasta acá

Este es el capítulo de la documentación que responde **una** pregunta:
*¿por qué esto quedó como quedó?* No responde ninguna otra.

Las cuatro preguntas del proyecto y dónde se responden:

| Pregunta | Fuente |
|---|---|
| ¿Qué debe ser? | `decisiones/` |
| ¿Cómo está hoy? | `db/actual/` |
| ¿Cómo funciona, explicado? | el resto de `agent-context/` |
| **¿Por qué llegó a ser así?** | **acá** |

La regla de rango no cambia porque este capítulo viva adentro de la
documentación: **describe el pasado, no gobierna el presente**. Si algo de acá
contradice a `decisiones/`, a `db/actual/` o a `AGENTS.md`, mandan ellos y esto
es simplemente lo que se pensaba entonces. Lo que está abierto hoy está en
`ROADMAP.md`; lo que se está cambiando, en `pedidos/`.

## La línea de tiempo

**Julio 2026 — el prototipo.** [`prototipo/`](prototipo/) es el chatbot anterior
a Chasqui: otro flujo de n8n, otra base. Nada del sistema actual depende de él;
está para ver de dónde salió la idea.

**Agosto 2026, semana 1 — las 73 migraciones.** [`migraciones/`](migraciones/)
son las que construyeron el sistema, acumulativas y con capas: 23.833 líneas,
263 definiciones de función para 163 nombres, `router_procesar_mensaje`
redefinida 15 veces. Ese mecanismo costó un fix perdido —el `periodo` de
`ingesta_resumen_sesion`, que la `046` agregó y la `051` borró sin mencionarlo— y
es el problema medido que fundamenta `ROUTER-001` y `MIGRACION-001`.

**Son imborrables y son inmutables**: 14 decisiones vigentes las citan en
`implementada_en` (el chequeo 6 de `bin/verificar.sh` valida que existan) y el
chequeo 3 detecta si alguna se modifica. Se leen para reconstruir un porqué,
nunca para saber cómo funciona algo hoy: para eso está `db/actual/`.

**Agosto 2026, semana 2 — las auditorías.**
[`auditorias/2026-08.md`](auditorias/2026-08.md) es la que inventarió el sistema
y disparó la reestructuración: el sellado de v0 en `db/base/`, el archivo de las
73 y el arranque de `db/migraciones/` en la `074`.
[`auditorias/2026-08-19/`](auditorias/2026-08-19/) es la de ingeniería inversa
que dio origen a esta capa; sus afirmaciones `[CONFIRMADO]` son la procedencia de
buena parte de lo que hoy afirman `../architecture/` y `../domains/`.

**Los planes.** [`planes/`](planes/) conserva `PLAN_PRODUCCION.md` y
`PLAN_DATOS_PRUEBA.md`: **ya ejecutados o superados**. Están acá porque varias
decisiones promovidas desde `decisiones/candidatos/` los citan como procedencia.
Ninguna de sus listas de pendientes vale hoy — lo pendiente está en `ROADMAP.md`.

## Cómo se usa este capítulo

1. Empezá por la cabecera de la migración o por `git log`. Casi siempre alcanza.
2. Si no alcanza, buscá acá el razonamiento completo.
3. Si lo que encontrás **debería** gobernar y no está escrito en `decisiones/`,
   eso no se resuelve leyendo: se escribe la decisión que faltaba, por un pedido.

## Lo que no se hace

- Citarlo para justificar un cambio: la justificación se escribe en `decisiones/`.
- Tomarlo como estado actual: eso es `db/actual/`.
- Tomar sus pendientes como pendientes: eso es `ROADMAP.md` y `pedidos/`.
- Editar `migraciones/`: son inmutables y `bin/verificar.sh` lo detecta.
- Mantener al día sus enlaces internos: son documentos cerrados; algunos apuntan
  a rutas que ya se movieron. Se leen como lo que son, papeles fechados.
