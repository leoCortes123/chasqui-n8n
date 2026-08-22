# agent-context — capa de contexto para agentes de IA

Mapa navegable y verificable del sistema **tal como existe hoy**, construido
por auditoría de ingeniería inversa. No duplica el código ni a `decisiones/`:
los referencia y agrega lo que falta para que un agente pueda ubicar,
condicionar y verificar un cambio sin leer el repositorio entero.

Desde el 2026-08-22 esta capa es **la única documentación descriptiva del
proyecto**: `docs/` dejó de existir y lo que estaba vivo se absorbió acá
(`DOCS-001`). Sigue siendo derivada: describe, no gobierna.

Fecha de la foto: **2026-08-21**. Fuentes primarias verificadas: `db/actual/`
(catálogo vivo volcado), `bin/gen_wf_*.py` (fuente real de los workflows),
`decisiones/` (normativo), `db/pruebas/`, `bin/verificar.sh`.

## Qué hay acá

| Carpeta | Qué contiene | Cuándo abrirlo |
|---|---|---|
| [`architecture/`](architecture/) | contexto, contenedores, componentes, flujos de datos y diagramas | para entender cómo encaja el sistema antes de tocarlo |
| [`domains/`](domains/) | un mapa por dominio: entradas, salidas, funciones canónicas, decisiones, invariantes, tests | cuando la tarea toca un dominio identificable |
| [`contracts/`](contracts/) | los contratos entre componentes que un cambio puede romper sin que compile nada | siempre que modifiques una frontera (n8n↔SQL, LLM, portal) |
| [`invariants/INVARIANTES.md`](invariants/INVARIANTES.md) | propiedades que deben seguir siendo verdaderas, con evidencia y verificación | antes de proponer cualquier cambio |
| [`navigation/`](navigation/) | índices por dominio, por componente y por tarea | punto de entrada para ubicar cualquier cosa |
| [`generated/`](generated/) | metadatos machine-readable derivados del código (`symbols.json`, etc.) | para consultas masivas (quién llama a quién, qué usa cada tabla) |
| [`audit/`](audit/) | desconocidos, discrepancias registradas (no corregidas) y cobertura | para saber qué NO está establecido y qué trampas ya se documentaron |
| [`product/`](product/) | qué ve el usuario final: guía funcional, UX de Telegram, WhatsApp | cuando la tarea toca la experiencia, no la mecánica |
| [`operations/`](operations/) | cómo se opera y se extiende: guía técnica, datos de prueba | para levantar, operar, generar datos o entender el diseño en prosa |
| [`reference/`](reference/) | detalle extenso: reglas de negocio, modelo de datos, seguridad, pruebas, memoria y estado, glosario | cuando el mapa del dominio no alcanza y hace falta la letra chica |
| [`interfaces/`](interfaces/) | las fronteras hacia afuera: API del portal, LLM, n8n | cuando el cambio cruza una de esas fronteras |
| [`history/`](history/) | por qué llegó a ser así: las 73 migraciones selladas, las auditorías, los planes ejecutados y el prototipo de julio | sólo cuando la cabecera de la migración y `git log` no alcanzan para reconstruir un porqué |
| [`source-of-truth.md`](source-of-truth.md) | qué fuente manda sobre qué tipo de información | obligatorio: primera lectura después de este README |

## Agent navigation protocol

Este protocolo **instancia** el protocolo de `AGENTS.md` (intención →
decisiones → realidad → impacto → contradicciones → propuesta); no lo
reemplaza. En orden:

1. Lee `AGENTS.md`. Define intención y dominios afectados de la tarea.
2. Abre [`navigation/by-task.md`](navigation/by-task.md) si la tarea es una de
   las tareas comunes listadas; si no, [`navigation/by-domain.md`](navigation/by-domain.md).
3. Del mapa del dominio toma: decisiones vigentes que lo gobiernan, invariantes
   aplicables y contratos en frontera. Lee esos archivos (son cortos).
4. Consulta [`audit/discrepancies.md`](audit/discrepancies.md) y
   [`audit/unknowns.md`](audit/unknowns.md) para no tropezar con lo ya registrado.
5. Localiza la implementación canónica con
   [`navigation/by-component.md`](navigation/by-component.md) y
   [`generated/symbols.json`](generated/symbols.json). El código vivo está en
   `db/actual/funciones/*.sql` y en `bin/gen_wf_*.py`; **nunca** en
   `db/migraciones/`, `agent-context/history/` ni `workflows/fotos/`.
6. Verifica impacto mecánico: `bash bin/impacto.sh <función>` (y
   `--tabla` para tablas). Para consultas masivas usa
   [`generated/dependencies.json`](generated/dependencies.json).
7. Contrasta tu plan contra los invariantes. Si contradice una decisión
   vigente, detente: la decisión nueva que la supersede se escribe **antes**
   (`decisiones/`, mismo commit).
8. Escribe el pedido (`pedidos/NNN-slug.md`, skill `/pedido`) y **espera la
   aprobación del humano**. Antes de eso no se toca nada (`PROCESO-001`).
9. Implementa siguiendo las restricciones de generación (`db/base/`,
   `db/actual/`, `workflows/wf_*.json` son generados: se cambia el generador y
   se regenera, jamás a mano).
10. Verifica: `bash bin/verificar.sh --rapido` (estructura), `bash bin/pruebas.sh`
   (bancos SQL, terminan en ROLLBACK), `python3 bin/prueba_ciclo_vida.py` (E2E).
   Si tocaste contratos de este directorio, actualízalos en el mismo commit.
11. Cierra el pedido: `aplicado`, con todas las tareas tildadas, a `pedidos/archivo/`.

## Reglas de esta capa

- Toda afirmación importante lleva evidencia (`ruta:función`) y, cuando aplica,
  etiqueta `CONFIRMADO` / `INFERIDO` / `UNKNOWN` / `CONTRADICTION`.
- Los ids son estables: `DOMAIN-*`, `CONTRACT-*`, `INV-*`, `CONCEPT-*`.
  Las decisiones conservan sus ids originales (`CORE-001`…) y viven en
  `decisiones/`: aquí se referencian, nunca se copian.
- Si esta capa discrepa del código, manda el código y regístralo en
  [`audit/discrepancies.md`](audit/discrepancies.md).
