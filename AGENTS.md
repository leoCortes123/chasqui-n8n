# AGENTS.md — Chasqui

Contrato para cualquier agente de código que trabaje en este repositorio.
Es normativo y corto. El conocimiento detallado vive en `decisiones/` y en `agent-context/`,
no aquí.

## Qué es Chasqui

Plataforma de **inteligencia y asistencia empresarial para pymes, no un ERP**.
El producto es el análisis: convertir ventas, compras, inventario, facturas y
proveedores en diagnósticos, oportunidades y acciones, con el ciclo
detectar → explicar → cuantificar → recomendar → ejecutar.

La pregunta que gobierna toda decisión:

> ¿Esta pieza hace que Chasqui entienda mejor el negocio, recomiende algo mejor
> o permita ejecutar una decisión?

Si la respuesta es no, queda fuera de prioridad.

## Tesis de diseño

n8n es un **runtime fijo de 7 workflows que casi nunca se tocan**. Todo el
comportamiento —pasos de la conversación, textos, umbrales, prompts, formatos
aceptados, reglas que disparan una recomendación, cuándo avisa y cuándo se
calla— **vive en filas de Postgres**.

- **Postgres hace** lo determinístico: parseo, normalización, matching, cálculo,
  máquina de estados, decisiones.
- **n8n hace** sólo lo que Postgres no puede: HTTP (LLM), descarga de archivos,
  reintentos con backoff. Nada de aritmética ni reglas de negocio en los nodos.

Regla que lo verifica: **si para lanzar un servicio nuevo hay que abrir el editor
de n8n, el diseño se rompió.** Agregar un servicio es un conjunto de `INSERT`.

## Restricciones (no son recomendaciones)

Este archivo es la **fuente** de R-I..R-IV y de la lista de congelados. Cualquier
otro documento que las mencione está citando, no definiendo: si discrepan, manda
esta tabla.

| # | Regla |
|---|---|
| **R-I** | **Postgres calcula; el LLM interpreta y redacta.** Ninguna cifra, umbral, regla financiera ni priorización puede vivir en un prompt ni derivarse de la salida del modelo. Corolario: está prohibido mover al LLM responsabilidades que hoy son de SQL; la dirección permitida es la contraria. |
| **R-II** | **Los datos nunca se destruyen por el plan del usuario.** El plan limita lectura y capacidad, jamás almacenamiento histórico. |
| **R-III** | **Una recomendación persiste después de la ejecución que la produjo** y puede evaluarse más tarde. |
| **R-IV** | **Cada pieza nueva aumenta el conocimiento del negocio, mejora una recomendación, o permite ejecutar/medir una decisión.** Si no se puede escribir la justificación, la pieza no entra. |

**Congelado** salvo que se demuestre que alimenta la capacidad de análisis:
cotizador · cobro automático, suscripciones y webhook Wompi · facturación
electrónica · PDF y Gotenberg · bot público · pgvector · Supabase · RLS ·
Directus · comparativos externos Nivel 2 y 3.

## Generado — nunca editar a mano

| Ruta | Se regenera con |
|---|---|
| `workflows/wf_*.json` | `bin/gen_wf_*.py` (lógica compartida en `bin/wf_lib.py`) |
| `db/actual/**` | `bin/gen_estado_sql.sh` (volcado del catálogo vivo de Postgres) |
| `db/base/**` | `bin/gen_base.sh` (sólo al rebasar; normalmente no se toca) |
| `decisiones/INDICE.md` | el generador de índice |

Editar cualquiera de estos a mano es una violación, y `bin/verificar.sh` la detecta.

`workflows/fotos/` es distinto: son exportaciones de n8n hechas por
`bin/exportar-workflows.sh` para poder reconstruir tras perder el volumen.
**No son fuente de nada** y pueden estar desfasadas. Para saber qué hace un
workflow se lee su generador o `workflows/wf_*.json`, nunca una foto.

## Prohibiciones

- No editar `workflows/*.json`: se cambia el generador y se regenera.
- No cambiar comportamiento de producto con `UPDATE` fuera de una migración.
- No modificar una migración ya aplicada: se escribe una migración nueva.
- No `docker compose down` ni recrear contenedores. Sólo `up -d`.
- No refactorizar por deuda descubierta de paso: se registra en `decisiones/deuda.md`.

## Herramientas de consulta

Tres servidores MCP, registrados en `.mcp.json`, deliberadamente separados:

| Servidor | Responde | Fuente |
|---|---|---|
| `decisiones` | ¿cómo hemos decidido que debe funcionar? | `decisiones/` (`bin/mcp_decisiones.py`) |
| `codigo` | ¿cómo está implementado hoy? | grafo de `codebase-memory-mcp` sobre `bin/`, `portal/`, `workflows/` y `db/actual/` |
| `quipu` | ¿qué microtarea puedo tomar y con qué evidencia se cierra? | Quipu (`http://localhost:8001/mcp`) — la columna de ejecución |

`codigo` **nunca** es fuente normativa: describe lo que hay, no lo que debe ser.
`quipu` **tampoco**: prueba lo que se construyó, no dice qué debe construirse.
La norma es `decisiones/`, y sólo `decisiones/` (`PROCESO-002`).

`codigo` sirve para el código Python/portal/shell y para búsqueda estructural,
pero **su grafo es ciego a PL/pgSQL**: tree-sitter deja sin parsear la mayoría de
las 160 funciones de `db/actual/funciones/` y no ve el despacho por filas
(`servicios.funcion_hallazgos` → `EXECUTE`). Para el grafo de llamadas y el
impacto sobre SQL manda `bash bin/impacto.sh <función>` y
`agent-context/generated/{symbols,dependencies}.json`, no `codigo`.

Sin cliente MCP, lo mismo se consulta a mano: `decisiones/INDICE.md`,
`db/actual/INDICE.md` y `bash bin/impacto.sh <función>`.

Para agentes: mapas por dominio, invariantes con evidencia, contratos entre
componentes y navegación por tarea viven en `agent-context/README.md`.

## Quipu — la columna de ejecución

Quipu es una app aparte (Laravel en `localhost:8001`, repo
`QUIPU_ENTERPRISE/code/api`) que traza el trabajo pieza a pieza y **exige prueba
de cada pieza**. Ahí está su valor: `mark_criterion_met` falla si no hay
evidencia enlazada, y `add_evidence` pide el output real. Una casilla `- [x]` no
falla nunca.

El proyecto `chasqui` está cargado (id 1, adoptado el 2026-08-27): 8 features,
43 rules, 8 bloques (P-002…P-009), 32 endpoints, 2 pantallas, 8 lecciones.

**El ciclo de ejecución** — es el paso 8 del protocolo, no un proceso aparte:

```
get_ready_blocks → get_block_detail → claim_block → plan_microtasks
  ↳ por microtarea: start_microtask → construir → add_evidence
                    → mark_criterion_met → complete_task
get_gate_status → complete_task (del bloque) → queda en `verifying`
```

Lo cierra un humano en la Web UI (`POST /api/blocks/{id}/approve`). **No hay tool
MCP para aprobar, y es deliberado.**

Antes de escribir código, dos consultas baratas: `query_knowledge` (¿ya se
cometió este error?) y `get_existing_components` (¿ya existe?). La segunda hoy
devuelve vacío —`code_class = 0`—; para impacto sobre SQL manda
`bash bin/impacto.sh`.

### Qué NO hace Quipu, y por eso `decisiones/` y `pedidos/` siguen en pie

Quipu **sí** tiene cadena de gobierno (`necesidad → cambio → requisito →
cobertura`, con seis puertas de cierre y firmas humanas). Lo que no tiene, medido
el 2026-08-28 (`PROCESO-002`):

- **No puede atar un cambio a los bloques de Chasqui.** `cambio_ambito()` alcanza
  los criterios de un bloque sólo por `feature.cambio_id`, y los 8 features son
  `es_heredado` con `cambio_id = NULL`. No hay tool que cree un bloque colgando
  de un cambio.
- **`business_rule` no tiene ciclo de vida**: sin `estado`, `supersede`,
  `motivo_reemplazo` ni `procedencia`. Las 43 rules son un **espejo de sólo
  lectura** de los invariantes; la norma vigente es `decisiones/`.
- **Ninguna puerta frena un bloque que contradiga una regla.** `block_rule` es
  una tabla que nada lee ni escribe, y el payload de `claim_block` no lleva
  reglas: el agente que reclama un bloque no ve un solo invariante. **Los
  invariantes se consultan en el MCP `decisiones`, siempre, antes del código.**
- R-I..R-IV, la lista de congelados y los 10 chequeos de `bin/verificar.sh` no
  tienen representación en Quipu.

Traducción de vocabulario, porque no coincide y eso ya costó cinco días de
Quipu invisible (`agent-context/history/metodologia/quipu-dormido.md`):

| Chasqui | Quipu |
|---|---|
| pedido | `cambio` + `requisitos` (hoy sin uso: no ata a bloques) |
| invariante | `business_rule` (espejo, sin ciclo de vida) |
| tarea del pedido | microtarea + criterio con evidencia |
| deuda / lección | `knowledge_entry` (`query_knowledge`) |
| contradicción | `enlace` sospechoso (`listar_sospechas`) — sin uso en este proyecto |

Si Quipu no responde en `localhost:8001`: `cd ../QUIPU_ENTERPRISE && docker
compose up -d`. Si aun así no está, el desarrollo **no se detiene** — se avanza
por el pedido y la evidencia se carga cuando vuelva.


## Comandos oficiales

```bash
docker compose up -d                 # levantar (nunca down)
bash bin/migrar.sh                   # aplicar migraciones pendientes
bash bin/gen_estado_sql.sh           # regenerar db/actual/ desde Postgres
python3 bin/gen_wf_<x>.py            # regenerar un workflow
bash bin/importar-workflows.sh       # importar y republicar en n8n
bash bin/pruebas.sh                  # los 7 bancos SQL (todo termina en ROLLBACK)
python3 bin/prueba_ciclo_vida.py     # E2E de un negocio por las rutas reales
bash bin/impacto.sh <función>        # quién la llama y a quién llama
bash bin/verificar.sh                # invariantes estructurales del repo
bash bin/verificar.sh --rapido       # sin los bancos SQL
bash bin/limpiar_negocio.sh          # borrar los datos de una prueba y empezar de cero
bash bin/pedidos.sh                  # qué cambios están en curso y qué les falta
```

## Limpiar entre pruebas

Los datos de las pruebas son generados. Cuando se pide limpiar la base para
probar desde cero, se corre `bash bin/limpiar_negocio.sh` y nada más: no se
pregunta el alcance, no se hace respaldo, no se ofrecen variantes. El script ya
sabe qué es dato de prueba y qué es Chasqui, y deja el negocio, el usuario y su
identidad de Telegram en pie para que la próxima carga entre por el mismo chat.

Si la base está ocupada, el script se rinde a los 15 segundos y dice quién la
tiene. **Se espera y se repite.** Nunca se matan procesos ni conexiones para
ganar un minuto: una corrida de n8n o un banco a medio correr, muertos por la
mitad, dejan un estado que después hay que adivinar.

## Cómo se instala y cómo se cambia

| Ruta | Qué es |
|---|---|
| `db/base/` | **Chasqui v0**: esquema completo + el contenido del sistema. Se aplica solo, una vez, sobre una base vacía |
| `db/migraciones/` | los cambios **desde** v0. Arranca en la `074` |
| `db/actual/` | la foto del estado vigente. Generada, para leer |
| `pedidos/` | los cambios en curso. Un cambio empieza acá (`PROCESO-001`) |
| `agent-context/history/migraciones/` | las 73 que construyeron v0. No se aplican y no gobiernan |

`bin/migrar.sh` hace las dos cosas: instala `db/base/` si la base está vacía y
después aplica lo pendiente.

Las 73 se archivaron porque el proyecto pasó por varias reestructuraciones sin
orden previo y las migraciones se acumularon en capas: 23.833 líneas, 263
definiciones de función para 163 nombres, `router_procesar_mensaje` redefinida
15 veces. Ya costó un fix perdido — el `periodo` de `ingesta_resumen_sesion`,
que la 046 agregó y la 051 borró sin mencionarlo. El esquema real cabe en 9.750
líneas.

**Para saber cómo está implementado algo hoy se consulta `db/actual/`**, nunca el
histórico. El porqué está en `decisiones/`; el histórico sólo se abre cuando hay
que reconstruir un razonamiento que no quedó en ninguna decisión.

## El comportamiento vive en filas

Los textos, botones, umbrales, prompts, servicios y formatos son **producto**, no
datos: viven en 12 tablas de contenido que `db/base/001_contenido.sql` instala y
`db/actual/contenido/` refleja.

La frontera es mecánica: una tabla con columna de pertenencia
(`negocio_id`, `usuario_id`, `sesion_id`, `chat_id`) tiene datos de quien opera
la instalación; sin ella, tiene producto. Cambiar contenido sigue siendo una
migración.

El criterio es necesario y no suficiente: una tabla de producto puede tener
filas que no lo son —un formato que el sistema APRENDIÓ de los archivos de un
cliente, la URL pública del túnel de turno— y esas no entran al baseline
(`BASE-001`, y `bin/verificar.sh` chequeo 8).

## Dónde viven las decisiones

`decisiones/` es la fuente normativa del proyecto: qué debe ser Chasqui.
Un archivo por decisión, con id de dominio (`ALERTAS-001`), estado
(`vigente` | `superada` | `descartada`), invariantes, alternativas descartadas,
relaciones (`supersede`, `superseded_by`, `relacionada_con`) y componentes
afectados (`implementada_en`, `afecta`).

- `decisiones/candidatos/` es material extraído automáticamente de migraciones,
  documentación y transcripts. **No es normativo.** Nada de ahí gobierna nada
  hasta que un humano lo revise y lo promueva.
- `decisiones/deuda.md` registra deuda descubierta y deliberadamente no corregida.

## Lo que NO gobierna

`agent-context/history/` es el capítulo de la documentación que responde **por
qué** algo quedó como quedó: las 73 migraciones selladas, las auditorías de
agosto de 2026, los planes ya ejecutados (A1..F2, migraciones 053-069) y el
prototipo de julio.

**Nada de ahí gobierna nada.** No se cita como justificación y no se toma como
estado actual. Se abre en un caso: reconstruir un razonamiento cuando la cabecera
de la migración y `git log` no alcanzan. Si contradice a `db/actual/`,
`decisiones/` o este archivo, manda cualquiera de esos tres y el capítulo es
simplemente lo que se pensaba entonces.

`agent-context/` es **la** documentación descriptiva del proyecto —no hay una
segunda: `docs/` dejó de existir el 2026-08-22 (`DOCS-001`)—. Describe, no
gobierna: si discrepa de `decisiones/` o de `db/actual/`, mandan ellos y la capa
está vieja. Eso vale en particular para la prosa larga que absorbió,
`agent-context/operations/guia-tecnica.md` y
`agent-context/product/guia-funcional.md`: útiles para entender el diseño, pero
uno envejece y el otro es la base.

## Configuración real del entorno

No está en ninguna migración a propósito: es entorno, no comportamiento de
producto. Verificado el 2026-08-18.

- **LLM**: `DEEPSEEK_BASE_URL=https://generativelanguage.googleapis.com/v1beta/openai`
  (proxy compatible con OpenAI). El endpoint no está hardcodeado: sale de esa
  variable vía `LLM_URL` en `bin/wf_lib.py` y se hornea en el JSON al generar.
- **Modelo**: `prompts.modelo` y `prompts_tecnicos.modelo` en
  `gemini-3.5-flash-lite` en los cuatro registros activos. El valor se puso con
  `UPDATE` directo y quedó horneado en `db/base/`, así que una instalación nueva
  ya nace con él; el DEFAULT de la columna sigue en `deepseek-v4-flash`, que no
  existe en este proxy. Dónde debe vivir el nombre del modelo —entorno o fila de
  producto— está sin decidir: `decisiones/deuda.md` D-007.
- **URL pública del portal**: `parametros.portal_url_base`. Es entorno, no
  producto: el baseline la instala VACÍA a propósito y la llena
  `bin/registrar-webhook.sh` con el túnel del momento, o `bin/preparar-portal.sh`
  con `WEBHOOK_URL`. Vacía, `/portal` responde `portal.sin_url` en vez de mandar
  un enlace con token a un dominio que ya no es de nadie (`BASE-001`).
- **Credencial de n8n** `chasquiDs0000000001`: vive en la base de n8n, no en el
  repo.
- **Servicios**: de este proyecto corren `postgres`, `n8n`, `postgrest` y
  `proxy`. Gotenberg no se levanta: está congelado.

## Protocolo obligatorio antes de modificar

**Primero intención, después realidad, después impacto, después modificación.**
No se empieza leyendo el repositorio entero.

| # | Paso | Herramienta |
|---|---|---|
| 1 | identificar el o los dominios que toca la solicitud | — |
| 2 | decisiones vigentes, superadas relevantes e invariantes | `dominio_contexto(dominio)` — MCP `decisiones` |
| 3 | estado real del código, **no** `db/migraciones/` | SQL: `db/actual/INDICE.md`. Resto y búsqueda estructural: `search_graph` — MCP `codigo` |
| 4 | dependencias e impacto | `bash bin/impacto.sh <función>` |
| 5 | contrastar la implementación contra los invariantes | — |
| 6 | **reportar las contradicciones antes de proponer nada** | — |
| 7 | **escribir el pedido** y esperar aprobación | skill `/pedido` → `pedidos/NNN-slug.md` |
| 8a | reclamar el bloque y planificar | `claim_block` → `plan_microtasks` — MCP `quipu` |
| 8b | construir cada microtarea **con evidencia real** | `start_microtask` → `add_evidence` → `mark_criterion_met` → `complete_task` |
| 9 | verificar, los dos | `get_gate_status` **y** `bash bin/verificar.sh` |
| 10 | registrar la decisión si cambió la arquitectura | `decisiones/`, mismo commit |
| 11 | cerrar: humano aprueba el bloque, pedido a `aplicado` y a `pedidos/archivo/` | Web UI de Quipu |

El paso 2 va **antes** que el 3, siempre. Un agente que explora primero llega al
paso 2 con una arquitectura ya formada en la cabeza, y entonces las decisiones
sólo la confirman o le estorban. En el paso 6 hay que distinguir dos cosas que se
parecen: lo que el usuario quiere que pase, y la deuda que ya está ahí.

Los pasos 1-7 son de Chasqui y **Quipu no participa**: no tiene ciclo de vida de
decisiones ni puerta que compruebe un invariante. Los pasos 8-9 son de Quipu, y
ahí una tarea del pedido se tilda **cuando su criterio quedó cumplido con
evidencia enlazada**, no cuando alguien decidió que ya estaba (`PROCESO-002`).

La evidencia es salida real: `bash bin/verificar.sh`, `bash bin/pruebas.sh`,
`bash bin/impacto.sh <función>`, el `git diff db/actual/`. Nunca un resumen —
`add_evidence` lo dice y `mark_criterion_met` falla sin evidencia enlazada.

Un cambio que no lleva SQL ni bloque —tocar un generador, un documento— se queda
en `pedidos/` y salta los pasos 8-9 de Quipu. Todo cambio necesita expediente; no
todo cambio necesita evidencia de construcción.

Que `dominio_contexto` devuelva vacío **no significa que se pueda hacer
cualquier cosa**: significa que la decisión no está escrita. Ante un cambio de
arquitectura sin decisión que lo gobierne, la decisión se escribe primero.

El paso 7 no es una formalidad: hasta que el pedido no está escrito y aprobado,
**no se toca nada** (`PROCESO-001`). Un pedido en `propuesto` no autoriza; el
estado es la autorización y lo cambia el humano, no el agente. **`claim_block`
sobre un bloque cuyo pedido no está en `aprobado` es ejecutar sin autorización**
— Quipu no lo impide, el protocolo sí (`PROCESO-002`).

## Los cambios en curso viven en `pedidos/`

Un cambio empieza por un archivo, no por una conversación: `pedidos/NNN-slug.md`,
con estado, decisiones consultadas, causa y tareas tildables. Lo escribe la skill
`/pedido` al final del protocolo; el humano lo aprueba cambiando el estado. El
formato y el ciclo de vida están en `pedidos/README.md`.

    propuesto ──aprueba el humano──► aprobado ──aplicado y verificado──► aplicado
        └──────────────rechaza──────────────────► descartado

**El pedido y su bloque son el mismo cambio visto desde dos lados**: el pedido
dice qué se cambia, por qué y quién lo autorizó; el bloque dice qué se construyó
y con qué prueba. Los 8 pedidos abiertos ya tienen bloque
(`chasqui-<dominio>-P-NNN`); un pedido nuevo que lleve SQL necesita el suyo.

Lo mecánico lo comprueba `bin/verificar.sh` chequeo 10: estados válidos,
coherencia con la carpeta, ninguna tarea sin tildar en un pedido `aplicado`, y
**ninguna migración desde la `077` sin un pedido que la nombre**. Los abiertos
salen solos al arrancar la sesión y con `bash bin/pedidos.sh`.

## Regla de contradicción

Una solicitud que contradice una decisión vigente **no se ejecuta en silencio**.
Se reporta:

> La solicitud contradice ALERTAS-001. Si esa decisión debe cambiar, primero se
> registra una decisión nueva que la supersede.

El usuario puede decidir cambiarla — pero la decisión nueva se escribe primero.

## Creación y modificación de decisiones

- Una decisión nueva se crea cuando cambia la arquitectura, una regla de negocio
  o una restricción; va en el mismo commit que el código.
- Una decisión no se edita para cambiar su sentido: se crea otra que la
  supersede, y la anterior pasa a `estado: superada` con `motivo_reemplazo`.
- Las decisiones superadas no se borran. Su valor es explicar qué se descartó.
