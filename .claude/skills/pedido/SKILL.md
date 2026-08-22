---
name: pedido
description: Convierte una descripción en lenguaje natural de un cambio en Chasqui en una solicitud bien formada según el protocolo del proyecto (dominio → decisiones vigentes → código → impacto → contradicciones → propuesta). Usar cuando el usuario pide un cambio, reporta algo que anda mal o describe un comportamiento que quiere distinto. NO ejecuta el cambio: produce la solicitud para que el usuario la apruebe.
---

# Redactar un pedido de cambio de Chasqui

El usuario describe lo que quiere en lenguaje natural. Esta skill produce **la
solicitud**, no el cambio. Terminar siempre en una propuesta que el usuario
aprueba o rechaza; no editar archivos ni base de datos durante la skill.

Si la descripción trae acciones ya decididas ("cambiá la plantilla X"), tratarlas
como hipótesis del usuario, no como la orden: el paso 1 puede demostrar que la
causa es otra.

## Paso 1 — Clasificar: ¿defecto o cambio de decisión?

Es la bifurcación que más se salta y la que hace perder el trabajo.

1. Identificar el **dominio** (el usuario puede declararlo; si no, inferirlo).
   Dominios con decisiones: consultar `dominio_contexto` sin argumentos.
2. Llamar `mcp__decisiones__dominio_contexto` con ese dominio. **Antes de leer
   una línea de código.** Sin cliente MCP: `decisiones/INDICE.md`.
3. Leer los invariantes vigentes y decidir cuál de los tres casos es:

| Caso | Señal | Qué se pide |
|---|---|---|
| **Defecto** | lo pedido ya es un invariante vigente y el sistema no lo cumple | corrección con causa identificada |
| **Cambio de contenido** | ningún invariante lo cubre; es texto, botón, umbral, prompt o formato | migración con `INSERT`/`UPDATE` (`CONTENIDO-001`) |
| **Cambio de decisión** | lo pedido **contradice** un invariante vigente | decisión nueva que supersede, antes del código |

Decirle al usuario cuál es, citando el invariante textual y su id. Si es defecto,
**no se toca la decisión ni el texto**: se busca la causa.

## Paso 2 — Exigir la evidencia mínima

Un pedido sin evidencia se acomoda al síntoma. Lo que hace falta según el caso:

- **Defecto:** fecha, canal, identificador de la corrida (`sesion_id`,
  `ejecucion_id`, `negocio_id`), qué se esperaba **por qué invariante**, y qué se
  vio. Si el usuario no lo tiene, obtenerlo de la base antes de seguir.
- **Cambio de contenido:** la clave de la plantilla o el parámetro, y el texto o
  valor nuevo exacto.
- **Cambio de decisión:** el problema **medido** que la justifica. Una decisión
  sin problema medido no entra.

Consulta para ubicar la sesión abierta de una prueba de usuario:

```bash
docker compose exec -T postgres psql -U postgres -d chasqui -c "
select s.id sesion, s.estado, s.servicio_codigo, s.panel_mensaje_id,
       s.analisis_pedido_en, s.creada_en, i.canal, i.datos->>'chat_id' chat
from sesiones s
join identidades i on i.usuario_id = s.usuario_id
where s.cerrada_en is null order by s.id desc;"
```

Otras fuentes de evidencia:

```bash
# qué falló y en qué nodo
docker compose exec -T postgres psql -U postgres -d chasqui -c \
  "select id,sesion_id,creada_en,detalle from fallas order by id desc limit 10;"
# ejecuciones de n8n — OJO: solo se guardan las que fallaron
docker compose exec -T postgres psql -U postgres -d n8n -tc \
  "select e.id,w.name,e.status,e.\"startedAt\" from execution_entity e
   join workflow_entity w on w.id=e.\"workflowId\" order by e.id desc limit 20;"
```

## Paso 3 — Código e impacto

Recién ahora se lee código, y se lee el estado vigente, no la historia:

- `db/actual/funciones/<f>.sql` — cómo está hoy. `db/migraciones/` es historia.
- `bash bin/impacto.sh <función>` — quién la llama y a quién llama.
- Contenido: `db/actual/contenido/plantillas.sql`, `parametros.sql`.
- Workflows: el **generador** `bin/gen_wf_*.py`, nunca `workflows/fotos/`.

## Paso 4 — Reportar contradicciones antes de proponer

Si el pedido choca con una decisión vigente, decirlo **antes** de la propuesta,
citando id e invariante. Si choca con un congelado de `AGENTS.md`, decirlo. Si el
pedido no puede responder R-IV, decirlo:

> ¿Esta pieza hace que Chasqui entienda mejor el negocio, recomiende algo mejor
> o permita ejecutar una decisión?

## Paso 5 — Escribir el pedido

La solicitud **no se emite en el chat: se escribe en `pedidos/`**. Un pedido que
sólo existe en la conversación muere con la sesión, y con él la clasificación,
las decisiones citadas y la causa. Ver `pedidos/README.md`.

El número es el siguiente disponible:

```bash
bash bin/pedidos.sh          # última línea: "El próximo pedido es el NNN"
```

Escribir `pedidos/NNN-slug.md` con este contenido exacto:

```markdown
---
id: P-NNN
titulo: <frase que se entiende sola>
dominio: <dominio>
clasificacion: defecto | contenido | decision | proceso
estado: propuesto
decisiones: [<IDs consultados en el paso 1>]
decision_nueva: null | <ID nuevo que supersede>
migracion: null | <NNN>_<nombre_en_snake_case>.sql
abierto: <YYYY-MM-DD>
cerrado: null
---

## Evidencia
<corrida, qué se esperaba **por qué invariante**, qué se vio>

## Causa
<ruta:línea — mecanismo>, o "sin confirmar: <cómo se confirma>"

## Cambio
<qué se toca exactamente>

## Tareas
- [ ] <cada paso ejecutable>
- [ ] regenerar: bin/gen_estado_sql.sh | python3 bin/gen_wf_<x>.py + bin/importar-workflows.sh | ninguno
- [ ] bash bin/verificar.sh
- [ ] <banco puntual de db/pruebas/>

## R-IV
<justificación en una línea>
```

El número de la migración es el siguiente al último de `db/migraciones/`:

```bash
ls db/migraciones/ | sort | tail -1
```

Escrito el archivo, resumir en el chat en cinco líneas —clasificación, decisión
que aplica, causa, cambio, migración— y **preguntar si se aprueba. No ejecutar
sin esa respuesta.** Escribir el pedido no es ejecutarlo: `estado: propuesto`
significa que nadie autorizó nada.

## Paso 6 — Después de la aprobación

Sólo cuando el humano aprueba:

1. `estado: aprobado` en el pedido. Recién ahí se toca código o base.
2. Se ejecuta tildando cada tarea **cuando corrió**, no antes. Una casilla
   tildada es una afirmación sobre lo que pasó.
3. Si el pedido lleva `decision_nueva`, la decisión se escribe **antes** del
   código y va en el mismo commit (`AGENTS.md` §creación de decisiones).
4. Con todo tildado y `bin/verificar.sh` sin violaciones: `estado: aplicado`,
   `cerrado: <fecha>`, y el archivo se mueve a `pedidos/archivo/`.
5. Si el humano lo rechaza: `estado: descartado`, el motivo escrito en el cuerpo,
   y también a `pedidos/archivo/`. **No se borra**: existe para que nadie
   reproponga lo mismo en tres meses.

`bin/verificar.sh` chequeo 10 comprueba lo mecánico de todo esto: estados
válidos, coherencia con la carpeta, ninguna tarea sin tildar en un pedido
`aplicado`, y ninguna migración desde la `077` sin un pedido que la nombre.

## Reglas que la skill no puede violar

De `AGENTS.md` y `decisiones/`:

- Nunca editar `workflows/*.json` a mano: se cambia el generador y se regenera.
- Nunca cambiar comportamiento con `UPDATE` fuera de una migración.
- Nunca modificar una migración ya aplicada: se escribe una nueva.
- Nunca editar lo generado: `db/actual/`, `db/base/`, `workflows/wf_*.json`.
- Nunca `docker compose down`. Solo `up -d`.
- Deuda descubierta de paso se registra en `decisiones/deuda.md`, no se corrige.
- Nunca ejecutar un pedido en `propuesto`: el estado es la autorización.
- Nunca tildar una tarea que no corrió.
- Una migración que agrega o quita un parámetro borra la firma que reemplaza
  (`MIGRACION-001`); una que cambia un estado del router reemplaza solo ese
  handler (`ROUTER-001`); una que toca una función RPC termina en `NOTIFY pgrst`
  (`PORTAL-001`).

## Si el pedido resulta ser un defecto sin causa confirmada

No proponer el cambio todavía. Proponer **cómo se confirma** (qué reproducir, qué
consultar) y esperar. Acomodar el texto o la prueba al síntoma es exactamente lo
que el protocolo existe para impedir.
