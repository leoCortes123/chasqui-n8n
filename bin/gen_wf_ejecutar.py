#!/usr/bin/env python3
"""Genera workflows/wf_ejecutar.json — el motor genérico de ejecución.
Recibe {ejecucion_id}, prepara (hallazgos+prompt en 1 llamada), llama a
DeepSeek, arma el informe, valida cifras Y que no haya quedado truncado
(reintenta 1 vez), cierra y devuelve el informe partido en mensajes de chat. No
sabe qué servicio corre: todo viene de la BD.

El informe se entrega como TEXTO en el chat, no como PDF: Gotenberg quedó fuera
del camino (el contenedor y plantillas_pdf siguen ahí para poder volver atrás).

El modelo NO escribe el informe formateado: devuelve JSON con la estructura
(titular, secciones, puntos, acciones) y el layout lo pone informe_render en
Postgres, con las piezas guardadas en `plantillas` (migración 025). Por eso el
render va ANTES de validar: lo que se valida es el texto que va a leer el
usuario, cabecera de métricas incluida.
"""
import json
from wf_lib import ERROR_WF_ID, LLM_URL

PG   = {"id": "chasquiPg0000000001", "name": "Chasqui Postgres"}
DS   = {"id": "chasquiDs0000000001", "name": "DeepSeek Header"}
TG   = {"id": "chasquiTg0000000001", "name": "Chasqui Telegram"}

def node(name, ntype, ver, params, pos, creds=None, extra=None):
    n = {"parameters": params, "id": name, "name": name,
         "type": ntype, "typeVersion": ver, "position": pos}
    if creds: n["credentials"] = creds
    if extra: n.update(extra)
    return n

def pg(name, query, pos, cont=False):
    p = {"operation": "executeQuery", "query": query, "options": {}}
    extra = {"onError": "continueRegularOutput"} if cont else None
    return node(name, "n8n-nodes-base.postgres", 2.6, p, pos,
                {"postgres": PG}, extra)

def code(name, js, pos):
    return node(name, "n8n-nodes-base.code", 2,
                {"jsCode": js}, pos)

nodes, conns = [], {}
def link(a, b, out="main", idx=0):
    conns.setdefault(a, {}).setdefault(out, [[]])
    while len(conns[a][out]) <= idx: conns[a][out].append([])
    conns[a][out][idx].append({"node": b, "type": "main", "index": 0})

# 1. Trigger de sub-workflow (n8n 2.x: el padre recibe la salida del hijo)
nodes.append(node("Inicio", "n8n-nodes-base.executeWorkflowTrigger", 1.1,
    {"inputSource": "passthrough"}, [0, 400]))

# 1b. "Escribiendo…" antes de arrancar (sendChatAction typing)
#
# El análisis tarda; el mensaje "⏳ Estoy analizando…" ya lo mandó el router,
# pero el indicador de actividad es lo que hace que la espera se sienta viva.
# Dura 5 segundos en Telegram: es un gesto de arranque, no una barra de
# progreso.
#
# Va EN LA CADENA y no como rama paralela a propósito: wf_ejecutar le devuelve
# al padre la salida del ÚLTIMO nodo ejecutado, y una rama suelta puede
# quedarse con ese lugar y dejar a wf_enviar sin informe que mandar. Como el
# item que llega a Preparar ya no es el del trigger, Preparar pasa a leer
# ejecucion_id de $('Inicio').
nodes.append(pg("CanalChat",
    "SELECT canal_de_chat("
    "COALESCE(NULLIF('{{ $('Inicio').first().json.chat_id ?? \"\" }}','')::bigint, 0)"
    ") AS canal;",
    [110, 400]))
link("Inicio", "CanalChat")

nodes.append(node("EsTelegram?", "n8n-nodes-base.if", 2.2, {
    "conditions": {"options": {"typeValidation": "loose"}, "combinator": "and",
        "conditions": [{"leftValue": "={{ $json.canal }}", "rightValue": "telegram",
            "operator": {"type": "string", "operation": "equals"}}]}}, [110, 260]))
link("CanalChat", "EsTelegram?")

# onError continue: que no se pueda pintar "escribiendo…" no puede impedir un
# análisis (chat de WhatsApp, ejecución manual sin chat_id, bot bloqueado).
nodes.append(node("Escribiendo", "n8n-nodes-base.telegram", 1.2, {
    "operation": "sendChatAction",
    "chatId": "={{ $('Inicio').first().json.chat_id }}",
    "action": "typing"}, [110, 140], {"telegramApi": TG},
    {"onError": "continueRegularOutput"}))
link("EsTelegram?", "Escribiendo", "main", 0)

# 2. Preparar: hallazgos + prompt + plantilla, con control de cupo
# Toma ejecucion_id del input; si no viene (ejecución manual de prueba), usa la
# última en estado 'preparando'.
nodes.append(pg("Preparar",
    "SELECT ejecucion_preparar( COALESCE( "
    "NULLIF('{{ $('Inicio').first().json.ejecucion_id ?? \"\" }}','')::bigint, "
    "(SELECT id FROM ejecuciones WHERE estado='preparando' ORDER BY id DESC LIMIT 1) "
    ") ) AS prep;",
    [220, 400]))
link("Escribiendo", "Preparar")
link("EsTelegram?", "Preparar", "main", 1)

# 3. ¿Bloqueado o sin prompt? -> salida temprana
nodes.append(node("Bloqueado?", "n8n-nodes-base.if", 2.2, {
    "conditions": {"options": {"caseSensitive": True, "typeValidation": "loose"},
        "combinator": "or", "conditions": [
        {"leftValue": "={{ $json.prep.bloqueado }}", "rightValue": True,
         "operator": {"type": "boolean", "operation": "true", "singleValue": True}},
        {"leftValue": "={{ $json.prep.error }}", "rightValue": "",
         "operator": {"type": "string", "operation": "exists", "singleValue": True}},
    ]}}, [440, 400]))
link("Preparar", "Bloqueado?")

# 3a. Rama bloqueado -> respuesta con plantilla, sin gastar tokens
nodes.append(code("RespBloqueo", """
const prep = $input.first().json.prep;
const plantilla = prep.bloqueado ? 'ejecucion.bloqueada_cupo' : 'ejecucion.fallida';
// Sin chat_id wf_enviar corre `SELECT (undefined)::bigint`. Acá no hubo cierre
// del que sacarlo, así que sale del input del sub-workflow.
let chat_id = null;
try { chat_id = $('Inicio').first().json.chat_id ?? null; } catch (e) {}
return [{ json: { chat_id, respuestas: [{ plantilla, vars: {
  limite: prep.limite ?? null } }] } }];
""", [660, 240]))
link("Bloqueado?", "RespBloqueo", "main", 0)  # true

# 4. Construir petición a DeepSeek (inyecta hallazgos en el prompt usuario)
# response_format json_object: el prompt pide estructura, no prosa, y así el
# modelo no puede envolverla en un párrafo de cortesía.
nodes.append(code("ArmarLLM", """
const prep = $input.first().json.prep;
const p = prep.prompt;
const usuario = p.usuario.replace('{{hallazgos}}', JSON.stringify(prep.hallazgos, null, 2));
return [{ json: {
  ejecucion_id: prep.ejecucion_id,
  hallazgos: prep.hallazgos,
  modelo: p.modelo, temperatura: p.temperatura, max_tokens: p.max_tokens,
  body: { model: p.modelo, temperature: p.temperatura, max_tokens: p.max_tokens,
    response_format: { type: 'json_object' },
    messages: [ {role:'system', content:p.sistema}, {role:'user', content:usuario} ] }
} }];
""", [660, 460]))
link("Bloqueado?", "ArmarLLM", "main", 1)  # false

# 5. DeepSeek (intento 1)
def ds_call(name, pos):
    return node(name, "n8n-nodes-base.httpRequest", 4.2, {
        "method": "POST", "url": LLM_URL,
        "authentication": "genericCredentialType", "genericAuthType": "httpHeaderAuth",
        "sendBody": True, "specifyBody": "json",
        "jsonBody": "={{ JSON.stringify($json.body) }}",
        "options": {"timeout": 120000}}, pos, {"httpHeaderAuth": DS},
        {"onError": "continueErrorOutput", "retryOnFail": True, "maxTries": 2})
nodes.append(ds_call("DeepSeek1", [880, 460]))
link("ArmarLLM", "DeepSeek1")

# 6. Extraer la estructura + tokens.
# Tres formas de que la respuesta no sirva, y las tres terminan en el mismo
# `invalido` para no multiplicar ramas:
#   * finish_reason 'length': se quedó sin cupo a mitad de frase (fue el bug del
#     "informe cortado": tokens_salida == max_tokens).
#   * el contenido no es JSON parseable.
#   * es JSON pero no un objeto.
def extraer(name, pos):
    return code(name, """
const src = $('ArmarLLM').first().json;
const r = $input.first().json;
const u = r.usage ?? {};
const truncado = r.choices?.[0]?.finish_reason === 'length';
// Con response_format json_object el cerco de ```json no debería aparecer, pero
// limpiarlo cuesta una línea y ya se vio pasar en wf_ingesta.
let txt = String(r.choices?.[0]?.message?.content ?? '')
  .replace(/^\\s*```(?:json)?/i, '').replace(/```\\s*$/, '').trim();
let estructura = null;
try { estructura = JSON.parse(txt); } catch (e) {}
const invalido = truncado || estructura === null || typeof estructura !== 'object'
                 || Array.isArray(estructura);
return [{ json: { ...src, estructura: invalido ? {} : estructura, bruto: txt,
  truncado, invalido,
  tokens_prompt: u.prompt_tokens ?? 0, tokens_salida: u.completion_tokens ?? 0 } }];
""", pos)
nodes.append(extraer("Extraer1", [1100, 460]))
link("DeepSeek1", "Extraer1", "main", 0)

# 6b. Render: el layout lo pone Postgres. Devuelve NULL si la estructura no
#     sirve, y ese NULL se trata igual que una cifra inventada.
def render(name, pos):
    return pg(name,
        "SELECT informe_render( "
        "'{{ JSON.stringify($json.estructura).replaceAll(\"'\",\"''\") }}'::jsonb, "
        "'{{ JSON.stringify($json.hallazgos).replaceAll(\"'\",\"''\") }}'::jsonb, "
        "(SELECT servicio_codigo FROM ejecuciones "
        "   WHERE id = ({{ $json.ejecucion_id }})::bigint) ) AS texto;",
        pos)
nodes.append(render("Render1", [1320, 460]))
link("Extraer1", "Render1")

# 6c. Validar cifras sobre el texto YA renderizado: es lo que va a leer el
#     usuario. Los hallazgos se leen del nodo de extracción porque el nodo de
#     Postgres solo devuelve las columnas de su consulta.
def validar(name, src, pos):
    return pg(name,
        "SELECT validar_cifras( "
        "'{{ String($json.texto ?? \"\").replaceAll(\"'\",\"''\") }}', "
        "'{{ JSON.stringify($('" + src + "').first().json.hallazgos).replaceAll(\"'\",\"''\") }}'"
        "::jsonb ) AS v;",
        pos)
nodes.append(validar("Validar1", "Extraer1", [1540, 460]))
link("Render1", "Validar1")

# 7. ¿Sirve? Si no, reintento único. Cifras inventadas, respuesta truncada y
#    estructura irrecuperable entran por la misma puerta.
def cifras_ok(name, ext, ren, pos):
    return node(name, "n8n-nodes-base.if", 2.2, {
        "conditions": {"options": {"typeValidation": "loose"}, "combinator": "and",
          "conditions": [{"leftValue":
            "={{ $json.v.ok === true"
            " && $('" + ext + "').first().json.invalido !== true"
            " && !!$('" + ren + "').first().json.texto }}",
            "rightValue": True,
            "operator": {"type": "boolean", "operation": "true", "singleValue": True}}]}},
        pos)
nodes.append(cifras_ok("Cifras1ok?", "Extraer1", "Render1", [1760, 460]))
link("Validar1", "Cifras1ok?")

# rama ok -> a la confluencia con el texto renderizado
nodes.append(code("TextoOK", """
const ctx = $('Extraer1').first().json;
return [{ json: { ...ctx, texto: $('Render1').first().json.texto, narrado: true } }];
""", [1980, 340]))
link("Cifras1ok?", "TextoOK", "main", 0)

# rama NO ok -> reintento
nodes.append(code("ArmarLLM2", """
const ctx = $('Extraer1').first().json;
return [{ json: { ...ctx, body: $('ArmarLLM').first().json.body } }];
""", [1980, 620]))
link("Cifras1ok?", "ArmarLLM2", "main", 1)
nodes.append(ds_call("DeepSeek2", [2200, 620]))
link("ArmarLLM2", "DeepSeek2")
nodes.append(extraer("Extraer2", [2420, 620]))
link("DeepSeek2", "Extraer2", "main", 0)
nodes.append(render("Render2", [2640, 620]))
link("Extraer2", "Render2")
nodes.append(validar("Validar2", "Extraer2", [2860, 620]))
link("Render2", "Validar2")
nodes.append(cifras_ok("Cifras2ok?", "Extraer2", "Render2", [3080, 620]))
link("Validar2", "Cifras2ok?")

nodes.append(code("TextoOK2", """
const ctx = $('Extraer2').first().json;
return [{ json: { ...ctx, texto: $('Render2').first().json.texto, narrado: true } }];
""", [3300, 480]))
link("Cifras2ok?", "TextoOK2", "main", 0)

# 2do intento falla -> se arma la estructura desde los hallazgos y se renderiza
# con la MISMA plantilla. El informe seco pierde la narración, no el formato: el
# usuario recibe algo que se lee igual de bien, con la nota de que el texto del
# modelo no se pudo verificar.
#
# El armado lo hace Postgres (informe_estructura_seca, migración 031): las
# listas de hallazgos son distintas en cada servicio, y ese conocimiento no
# puede vivir en un nodo. Acá quedan dos pasos porque un nodo de Postgres
# devuelve solo las columnas de su consulta y el contexto (ejecucion_id, tokens)
# tiene que seguir viajando.
# Ojo con el input: lo que llega por esta rama es la salida de Validar2 (solo la
# columna `v`), así que el contexto se toma del nodo de extracción, igual que
# hace Validar.
nodes.append(pg("SecaSQL",
    "SELECT informe_estructura_seca( "
    "'{{ JSON.stringify($('Extraer2').first().json.hallazgos).replaceAll(\"'\",\"''\") }}'::jsonb, "
    "(SELECT servicio_codigo FROM ejecuciones "
    "   WHERE id = ({{ $('Extraer2').first().json.ejecucion_id }})::bigint) ) AS estructura;",
    [3300, 760]))
link("Cifras2ok?", "SecaSQL", "main", 1)

nodes.append(code("EstructuraSeca", """
const ctx = $('Extraer2').first().json;
return [{ json: { ...ctx, estructura: $input.first().json.estructura } }];
""", [3520, 760]))
link("SecaSQL", "EstructuraSeca")
nodes.append(render("RenderSeco", [3740, 760]))
link("EstructuraSeca", "RenderSeco")
nodes.append(code("TextoSeco", """
const ctx = $('EstructuraSeca').first().json;
return [{ json: { ...ctx, texto: $('RenderSeco').first().json.texto, narrado: false } }];
""", [3960, 760]))
link("RenderSeco", "TextoSeco")

# 8. Confluencia. Los 3 caminos llevan {texto, ejecucion_id, tokens_*, narrado}.
#    El texto ya viene en HTML de Telegram y con las variables escapadas por
#    informe_render, así que acá no se toca: cualquier "limpieza" extra podría
#    romper una etiqueta o mutilar un nombre de producto.
nodes.append(code("Consolidar", """
const c = $input.first().json;
return [{ json: { ...c, texto: String(c.texto || '').trim() } }];
""", [3960, 480]))
for src in ("TextoOK", "TextoOK2", "TextoSeco"):
    link(src, "Consolidar")

# 9. Cerrar ejecución con texto+tokens. El PDF ya no se genera; la columna
#    ejecuciones.pdf queda en NULL y ejecucion_cerrar la deja como estaba.
nodes.append(pg("Cerrar",
    "SELECT ejecucion_cerrar( "
    "({{ $json.ejecucion_id }})::bigint, 'completada', "
    "jsonb_build_object("
    "  'texto', '{{ String($json.texto).replaceAll(\"'\",\"''\") }}',"
    "  'tokens_prompt', {{ $json.tokens_prompt || 0 }},"
    "  'tokens_salida', {{ $json.tokens_salida || 0 }}"
    ") ) AS cierre;",
    [4180, 480]))
link("Consolidar", "Cerrar")

# 10. Respuesta final para wf_router: el informe partido en mensajes.
#     Telegram corta en 4096 caracteres, así que un informe largo se parte por
#     bloques. wf_enviar manda un mensaje por cada elemento de respuestas[], así
#     que partir acá no le exige ningún cambio.
nodes.append(code("RespFinal", """
const c = $('Consolidar').first().json;
// El chat_id venía sin definir y wf_enviar terminaba corriendo
// `SELECT (undefined)::bigint`: el informe se generaba y no se entregaba.
// ejecucion_cerrar lo resuelve desde la base (ejecución -> sesión -> usuario);
// el input del sub-workflow es el respaldo cuando sí vino de un chat.
const cierre = $('Cerrar').first().json.cierre || {};
let chat_id = cierre.chat_id ?? null;
if (chat_id == null) { try { chat_id = $('Inicio').first().json.chat_id ?? null; } catch (e) {} }

// Las dos plantillas de entrega son solo {{texto}}, así que no hay encabezado
// que descontar. El margen sobre los 4096 de Telegram cubre los emojis y las
// etiquetas HTML, que cuentan más de un carácter en bytes.
const LIM = 3800;

function partir(texto, limite) {
  const partes = [];
  let actual = '';
  // Corta por bloque (informe_render los separa con línea en blanco); si un
  // bloque solo ya excede el límite, corta por línea; si una línea sola excede,
  // corta a lo bruto. Nunca pierde texto.
  //
  // Ninguna etiqueta HTML del informe abarca más de una línea (informe_render se
  // encarga: los <b> van en títulos y métricas, y el cuerpo de cada viñeta va
  // sin marcar). Por eso ningún corte puede dejar un <b> sin su cierre, que es
  // lo que Telegram rechaza con 400.
  const bloques = [];
  for (const bloque of texto.split(/\\n{2,}/)) {
    if (bloque.length <= limite) { bloques.push(bloque); continue; }
    for (const linea of bloque.split('\\n')) {
      if (linea.length <= limite) { bloques.push(linea); continue; }
      for (let i = 0; i < linea.length; i += limite) bloques.push(linea.slice(i, i + limite));
    }
  }
  for (const b of bloques) {
    const cand = actual ? actual + '\\n\\n' + b : b;
    if (cand.length > limite && actual) { partes.push(actual); actual = b; }
    else { actual = cand; }
  }
  if (actual) partes.push(actual);
  return partes.length ? partes : [''];
}

const partes = partir(c.texto || '', LIM);
// El teclado vive en la fila de la plantilla de entrega, así que esa plantilla
// se reserva para el ÚLTIMO mensaje: los botones tienen que quedar al final del
// informe, no en la mitad. CUÁL es esa plantilla lo decide ejecucion_cerrar
// (migración 032): después de una respuesta de la base de conocimiento, ofrecer
// "analizar otra vez" no tiene sentido, y esa es una decisión del servicio.
const entrega = cierre.plantilla_entrega || 'ejecucion.entregada';
const respuestas = partes.map((texto, i) => ({
  plantilla: i === partes.length - 1 ? entrega : 'ejecucion.informe_parte',
  vars: { texto } }));

return [{ json: { chat_id, respuestas, narrado: c.narrado, partes: partes.length } }];
""", [4400, 480]))
link("Cerrar", "RespFinal")

wf = {"id": "wfEjecutar000000001", "name": "wf_ejecutar",
      "nodes": nodes, "connections": conns,
      "settings": {"executionOrder": "v1", "errorWorkflow": ERROR_WF_ID},
      "active": False}
open("workflows/wf_ejecutar.json", "w").write(json.dumps(wf, indent=2, ensure_ascii=False))
print("wf_ejecutar.json:", len(nodes), "nodos")
