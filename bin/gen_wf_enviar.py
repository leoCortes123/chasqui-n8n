#!/usr/bin/env python3
"""wf_enviar — único punto de salida al canal. Recibe {chat_id, respuestas[]}
y opcionalmente un binario 'documento'. Resuelve cada plantilla en Postgres y
manda por Telegram. Texto y documento en dos ramas desde el trigger.

Los botones vienen resueltos de la base: resolver_plantilla devuelve el
reply_markup ya armado (ver migración 023). Una respuesta puede traer su propio
`teclado` para pisar el de la fila —lo usa el router para la lista de servicios,
que es dinámica—.

POR QUÉ HAY UN NODO DE ENVÍO POR CANTIDAD DE FILAS
--------------------------------------------------
El nodo de Telegram de n8n no acepta un reply_markup ya armado. `getNodeParameter`
resuelve los parámetros contra la DESCRIPCIÓN del nodo y descarta todo lo que no
esté declarado ahí, así que la FORMA del teclado (cuántas filas, cuántos botones)
tiene que estar literal en el workflow; solo las hojas —el texto del botón y su
callback_data— pueden salir de una expresión.

Comprobado con cinco sondas contra la API real, mirando si Telegram devuelve
`reply_markup` en la respuesta:

  A  additionalFields.reply_markup (objeto o string)   -> se descarta
  B  inlineKeyboard entero por expresión               -> teclado vacío
  E  el array `buttons` de la fila por expresión       -> llegan los botones pero
                                                          SIN callback_data:
                                                          "Text buttons are
                                                          unallowed in the inline
                                                          keyboard"
  F  el objeto `row` por expresión                     -> teclado vacío
  D  forma literal + expresiones en las hojas          -> FUNCIONA

De ahí el diseño: `Filas` aplana el teclado a un botón por fila y el Switch elige
el nodo que tiene esa cantidad de filas literales. Lo único que queda fijo en el
workflow es el tope de filas; el contenido sigue viviendo en la base.

La alternativa limpia —un nodo HTTP Request contra api.telegram.org, con control
total del body— necesita el token del bot dentro del contenedor de n8n
(TELEGRAM_BOT_TOKEN hoy solo lo ve el servicio `registrador`), y agregarlo obliga
a recrear el contenedor. Queda pendiente de decisión.

MENÚS QUE SE REEMPLAZAN EN VEZ DE APILARSE (070)
------------------------------------------------
Una respuesta puede traer `editar` con el id del mensaje que trae el botón que
el usuario tocó. Cuando viene, la pantalla se actualiza en su lugar
(editMessageText) y el chat no se llena de menús muertos. Quién puede
reemplazarse lo decide la base (`plantillas.reemplaza`); el id lo pone
`router_marcar_editables` en wf_router, que es quien lo tiene.

Eso duplica el switch por cantidad de filas: la limitación de arriba obliga a
tener un nodo por forma de teclado también del lado de la edición. A cambio, el
generador arma las dos ramas con la misma función y el tope sigue siendo uno.
"""
import os, sys
from wf_lib import WF, PG, TG, WA, GRAPH

# Embebido en las URLs de la Graph API al generar (mismo criterio que el secreto
# en wf_router). Sin él el workflow igual sirve: la rama WhatsApp solo corre
# para chats cuyo canal resuelto sea whatsapp, y sin credenciales no hay nadie así.
WA_PNID = os.environ.get("WA_PHONE_NUMBER_ID", "")
if not WA_PNID:
    print("aviso: WA_PHONE_NUMBER_ID vacío; la rama WhatsApp queda generada "
          "pero no funcional hasta regenerar con el .env completo", file=sys.stderr)

# Tope de filas del teclado. Cada fila lleva UN botón: en un chat, una lista
# vertical se lee mejor que una parrilla, y así el aplanado es trivial.
# Subirlo es cambiar este número y regenerar; teclado_markup en la base aplica el
# mismo tope (migración 027) para que no pueda existir un teclado que el
# enviador no sepa expresar.
MAX_FILAS = 6

w = WF("wfEnviar00000000001", "wf_enviar")

w.node("Inicio", "n8n-nodes-base.executeWorkflowTrigger", 1.1,
       {"inputSource": "passthrough"}, [0, 300])

# --- Rama texto ---------------------------------------------------------------
w.code("Expandir", """
const inp = $input.first().json;
const chat = inp.chat_id;
const out = [];
for (const r of (inp.respuestas || [])) {
  if (r.plantilla) out.push({ json: {
    chat_id: chat, plantilla: r.plantilla, vars: r.vars || {},
    // null explícito: la plantilla se queda con el teclado de su fila.
    teclado: r.teclado ?? null,
    // 070: id del mensaje a reemplazar. Lo pone router_marcar_editables solo
    // cuando la pantalla es de navegación y el update fue un toque de botón.
    editar: r.editar ?? null } });
}
return out;
""", [220, 200])
w.link("Inicio", "Expandir")

# Además de resolver la plantilla, decide el canal del chat (044) y, si es
# WhatsApp, deja armados los cuerpos para la Graph API: texto convertido de
# HTML y teclado traducido a botones/lista. Todo el formato sigue en la base.
w.pg("Resolver",
     "SELECT c.chat_id, c.canal, "
     "res ->> 'texto'  AS texto, "
     "res -> 'teclado' AS teclado, "
     # El nodo Postgres solo deja pasar lo que selecciona, así que `editar`
     # tiene que viajar explícito o se pierde acá.
     "nullif('{{ $json.editar ?? \"\" }}', '')::bigint AS editar, "
     "CASE WHEN c.canal = 'whatsapp' THEN "
     "wa_payload(c.chat_id::text, wa_texto(res ->> 'texto'), res -> 'teclado') "
     "END AS wa "
     "FROM resolver_plantilla('{{ $json.plantilla }}', "
     "'{{ JSON.stringify($json.vars).replaceAll(\"'\",\"''\") }}'::jsonb, "
     "'{{ JSON.stringify($json.teclado ?? null).replaceAll(\"'\",\"''\") }}'::jsonb"
     ") AS t(res), "
     "LATERAL (SELECT ({{ $json.chat_id }})::bigint AS chat_id, "
     "canal_de_chat(({{ $json.chat_id }})::bigint) AS canal) c;",
     [440, 200])
w.link("Expandir", "Resolver")

# --- Bifurcación por canal ----------------------------------------------------
w.if_("EsWa?", "={{ $json.canal === 'whatsapp' }}", [560, 340])
w.link("Resolver", "EsWa?")

# wa_payload devuelve un ARRAY de cuerpos (texto largo + botones = 2 mensajes).
w.code("PartirWa", """
const out = [];
for (const item of $input.all())
  for (const body of (item.json.wa || []))
    out.push({ json: { chat_id: item.json.chat_id, body } });
return out;
""", [720, 460])
w.link("EsWa?", "PartirWa", 0)

# HTTP Request directo a la Graph API: acá no hay la limitación del nodo de
# Telegram, el body entero sale de una expresión. Mismo criterio de errores que
# EnviarTexto: sin onError (un mensaje que no llega tiene que verse) y con retry.
w.node("EnviarWa", "n8n-nodes-base.httpRequest", 4.2, {
    "method": "POST", "url": f"{GRAPH}/{WA_PNID}/messages",
    "authentication": "genericCredentialType", "genericAuthType": "httpHeaderAuth",
    "sendBody": True, "specifyBody": "json",
    "jsonBody": "={{ JSON.stringify($json.body) }}",
    "options": {"timeout": 30000}}, [900, 460], {"httpHeaderAuth": WA},
    {"retryOnFail": True, "maxTries": 3, "waitBetweenTries": 2000})
w.link("PartirWa", "EnviarWa")

# Aplana el teclado a un botón por fila y rellena los huecos, para que las
# expresiones de los nodos de envío nunca apunten a un índice inexistente.
w.code("Filas", f"""
const j = $input.first().json;
const MAX = {MAX_FILAS};
const btns = [];
for (const fila of (j.teclado?.inline_keyboard || []))
  for (const b of (fila || []))
    if (b && b.text && b.callback_data) btns.push({{ text: b.text, dato: b.callback_data }});
const usados = btns.slice(0, MAX);
const relleno = Array.from({{ length: MAX - usados.length }}, () => ({{ text: '', dato: '' }}));
return [{{ json: {{ ...j, n: usados.length, b: usados.concat(relleno) }} }}];
""", [660, 200])
w.link("EsWa?", "Filas", 1)

# La pantalla que llegó por botón y está marcada como navegable (070) se edita
# en su lugar; todo lo demás se manda como mensaje nuevo.
w.if_("EsEdicion?", "={{ !!$json.editar }}", [760, 200])
w.link("Filas", "EsEdicion?")


def switch_filas(name, pos):
    return w.node(name, "n8n-nodes-base.switch", 3, {
        "rules": {"values": [
            {"conditions": {"options": {"typeValidation": "loose"}, "combinator": "and",
                "conditions": [{"leftValue": "={{ $json.n }}", "rightValue": k,
                    "operator": {"type": "number", "operation": "equals"}}]},
             "outputKey": f"filas{k}"}
            for k in range(MAX_FILAS + 1)]},
        "options": {}}, pos)


switch_filas("CuantasFilas", [880, 200])
w.link("EsEdicion?", "CuantasFilas", 1)
switch_filas("CuantasFilasEd", [880, -420])
w.link("EsEdicion?", "CuantasFilasEd", 0)

# appendAttribution: false quita el "This message was sent automatically with
# n8n" que el nodo agrega por defecto al final de cada mensaje.
#
# parse_mode HTML explícito. No existe "sin parse_mode": el nodo fuerza Markdown
# cuando no se le pide otra cosa (GenericFunctions.js:29), y el Markdown legacy
# revienta el mensaje entero ante un guion bajo suelto —un código de servicio
# como `ventas_compras` alcanzaba—. HTML es el único modo con una regla de escape
# simple, y resolver_plantilla escapa los valores de las variables (migración 022).
#
# SIN onError: un mensaje que no llega es un fallo real y tiene que verse. Con
# `continueRegularOutput` la ejecución quedaba marcada como exitosa, no se
# guardaba nada (EXECUTIONS_DATA_SAVE_ON_SUCCESS=none) y el informe simplemente
# no aparecía en el chat sin dejar rastro en ningún lado. Ahora falla, wf_error
# lo registra en `fallas` y avisa. retryOnFail cubre el hipo transitorio.
def teclado_literal(filas):
    """La forma del teclado, literal; solo las hojas salen de expresiones."""
    if not filas:
        return {}
    return {"replyMarkup": "inlineKeyboard",
            "inlineKeyboard": {"rows": [
                {"row": {"buttons": [{
                    "text": f"={{{{ $json.b[{i}].text }}}}",
                    "additionalFields": {"callback_data": f"={{{{ $json.b[{i}].dato }}}}"}}]}}
                for i in range(filas)]}}


def enviar_texto(filas, pos):
    params = {
        "chatId": "={{ $json.chat_id }}",
        "text": "={{ $json.texto }}",
        "additionalFields": {"appendAttribution": False, "parse_mode": "HTML"}}
    params.update(teclado_literal(filas))
    return w.node(f"EnviarTexto{filas}", "n8n-nodes-base.telegram", 1.2, params,
                  pos, {"telegramApi": TG},
                  {"retryOnFail": True, "maxTries": 3, "waitBetweenTries": 2000})

for k in range(MAX_FILAS + 1):
    enviar_texto(k, [1100, 40 + k * 110])
    w.link("CuantasFilas", f"EnviarTexto{k}", k)


# --- Rama edición (070) -------------------------------------------------------
# Mismo diseño que la de envío y por la misma razón (la forma del teclado tiene
# que ser literal), con dos diferencias:
#
#   * `messageId` apunta al mensaje que trae el botón que el usuario tocó.
#   * onError continueErrorOutput: editar puede fallar por motivos que NO son
#     un fallo del sistema —Telegram rechaza editar un mensaje de más de 48 h, y
#     devuelve 400 "message is not modified" si el contenido es idéntico—. La
#     salida de error va a `EdicionFallo?`, que descarta el "not modified" (la
#     pantalla ya muestra eso: no hay nada que hacer) y manda el resto por la
#     rama de envío normal. Así una edición imposible degrada a mensaje nuevo en
#     vez de dejar al usuario sin respuesta.
def editar_texto(filas, pos):
    params = {
        "operation": "editMessageText",
        "messageType": "message",
        "chatId": "={{ $json.chat_id }}",
        "messageId": "={{ $json.editar }}",
        "text": "={{ $json.texto }}",
        "additionalFields": {"appendAttribution": False, "parse_mode": "HTML"}}
    params.update(teclado_literal(filas))
    return w.node(f"EditarTexto{filas}", "n8n-nodes-base.telegram", 1.2, params,
                  pos, {"telegramApi": TG},
                  {"onError": "continueErrorOutput",
                   "retryOnFail": True, "maxTries": 2, "waitBetweenTries": 1000})

for k in range(MAX_FILAS + 1):
    editar_texto(k, [1100, -580 + k * 110])
    w.link("CuantasFilasEd", f"EditarTexto{k}", k)
    w.link(f"EditarTexto{k}", "EdicionFallo?", 1)   # salida de error

w.if_("EdicionFallo?",
      "={{ !String($json.error?.message ?? $json.error ?? '').includes('not modified') }}",
      [1320, -420])
w.link("EdicionFallo?", "CuantasFilas", 0)

# --- Rama panel de carga (071) ------------------------------------------------
# Un solo mensaje que se edita en su lugar mientras entran archivos, y que queda
# fijado para que el usuario no tenga que scrollear a buscar el botón. Vive acá
# y no en un workflow nuevo porque wf_enviar ya es el único punto de salida al
# canal; wf_router y wf_ingesta solo mandan {panel:{sesion_id, modo}}.
#
# El teclado vuelve a tener que ser literal (misma limitación del nodo de
# Telegram explicada arriba), pero acá el problema es chico: el panel tiene tres
# formas posibles y ninguna pasa de dos filas.
#
# Diferencia con la rama de texto: acá HAY QUE recuperar el message_id del
# mensaje recién mandado para poder editarlo la próxima vez. Por eso el envío no
# termina en el nodo de Telegram sino en PanelGuardar.
PANEL_FILAS = 2

w.if_("EsPanel?", "={{ !!$json.panel }}", [220, 1200])
w.link("Inicio", "EsPanel?")

# carga_panel puede devolver NULL si la sesión ya no existe: en ese caso todo
# viene en NULL y PanelHay? corta sin mandar nada.
w.pg("PanelResolver",
     "SELECT p ->> 'chat_id' AS chat_id, p ->> 'canal' AS canal, "
     "p ->> 'mensaje_id' AS mensaje_id, p ->> 'texto' AS texto, "
     "p -> 'teclado' AS teclado, "
     # Mismo criterio que la rama de texto: si el chat es de WhatsApp el cuerpo
     # para la Graph API se arma en la base, no en el nodo.
     "CASE WHEN p ->> 'canal' = 'whatsapp' THEN "
     "wa_payload(p ->> 'chat_id', wa_texto(p ->> 'texto'), p -> 'teclado') "
     "END AS wa "
     "FROM (SELECT carga_panel( "
     "({{ $json.panel.sesion_id }})::bigint, "
     "'{{ ($json.panel.modo ?? \"panel\").replaceAll(\"'\",\"''\") }}') AS p) t;",
     [400, 1200])
w.link("EsPanel?", "PanelResolver", 0)

w.if_("PanelHay?", "={{ !!$json.texto }}", [560, 1200])
w.link("PanelResolver", "PanelHay?")

# Mismo aplanado que `Filas`, más el sesion_id que el nodo de Postgres se comió
# y que PanelGuardar necesita de vuelta.
w.code("PanelFilas", f"""
const j = $input.first().json;
const MAX = {PANEL_FILAS};
const btns = [];
for (const fila of (j.teclado?.inline_keyboard || []))
  for (const b of (fila || []))
    if (b && b.text && b.callback_data) btns.push({{ text: b.text, dato: b.callback_data }});
const usados = btns.slice(0, MAX);
const relleno = Array.from({{ length: MAX - usados.length }}, () => ({{ text: '', dato: '' }}));
return [{{ json: {{ ...j, sesion_id: $('Inicio').first().json.panel.sesion_id,
  n: usados.length, b: usados.concat(relleno) }} }}];
""", [720, 1200])
w.link("PanelHay?", "PanelFilas", 0)

# WhatsApp no sabe editar ni fijar (044/070): allá el panel sale como mensaje
# nuevo por la rama de siempre y no se guarda ningún id.
w.if_("PanelEsTg?", "={{ $json.canal !== 'whatsapp' }}", [880, 1200])
w.link("PanelFilas", "PanelEsTg?")
# En WhatsApp el panel degrada a un mensaje más y sale por la rama que ya existe.
# Va conectado y no suelto a propósito: una salida sin conectar es exactamente el
# descarte silencioso que esta tanda vino a eliminar.
w.link("PanelEsTg?", "PartirWa", 1)

w.if_("PanelEditar?", "={{ !!$json.mensaje_id }}", [1040, 1200])
w.link("PanelEsTg?", "PanelEditar?", 0)


def panel_switch(name, pos):
    return w.node(name, "n8n-nodes-base.switch", 3, {
        "rules": {"values": [
            {"conditions": {"options": {"typeValidation": "loose"}, "combinator": "and",
                "conditions": [{"leftValue": "={{ $json.n }}", "rightValue": k,
                    "operator": {"type": "number", "operation": "equals"}}]},
             "outputKey": f"filas{k}"}
            for k in range(PANEL_FILAS + 1)]},
        "options": {}}, pos)


# --- Crear el panel (primera vez) ---
panel_switch("PanelCuantas", [1200, 1320])
w.link("PanelEditar?", "PanelCuantas", 1)

for k in range(PANEL_FILAS + 1):
    params = {
        "chatId": "={{ $json.chat_id }}",
        "text": "={{ $json.texto }}",
        "additionalFields": {"appendAttribution": False, "parse_mode": "HTML"}}
    params.update(teclado_literal(k))
    w.node(f"PanelCrear{k}", "n8n-nodes-base.telegram", 1.2, params,
           [1400, 1180 + k * 110], {"telegramApi": TG},
           {"retryOnFail": True, "maxTries": 3, "waitBetweenTries": 2000})
    w.link("PanelCuantas", f"PanelCrear{k}", k)
    w.link(f"PanelCrear{k}", "PanelGuardar")

# El id del mensaje recién creado se guarda en la sesión: es lo que convierte al
# panel en UN mensaje que se edita, en vez de uno nuevo por archivo.
# Devuelve el message_id además de guardarlo: PanelFijar lo necesita y no puede
# leerlo de PanelCrear{k} porque solo uno de los tres nodos corrió.
#
# `$json.result.message_id` y NO `$json.message_id`: el nodo de Telegram devuelve
# el SOBRE completo de la API —`returnJsonArray(responseData)`, Telegram.node.js
# línea 2340—, no `responseData.result`. Con la ruta equivocada la consulta salía
# como `SELECT (undefined)::bigint`, el guardado fallaba, `panel_mensaje_id`
# quedaba NULL y cada refresco mandaba un panel NUEVO en vez de editar el que ya
# estaba. Visto en la segunda prueba de usuario.
w.pg("PanelGuardar",
     "SELECT ({{ $json.result.message_id }})::bigint AS mensaje_id "
     "FROM carga_panel_registrar("
     "({{ $('PanelFilas').first().json.sesion_id }})::bigint, "
     "({{ $json.result.message_id }})::bigint);",
     [1620, 1320])

# Fijarlo es lo que evita que el usuario tenga que volver a buscarlo entre 100
# archivos. Solo al crearlo. onError: fijar puede fallar si el usuario le quitó
# el permiso al bot, y eso no puede impedir que el panel exista.
w.node("PanelFijar", "n8n-nodes-base.telegram", 1.2, {
    "resource": "chat",
    "operation": "pinChatMessage",
    "chatId": "={{ $('PanelFilas').first().json.chat_id }}",
    "messageId": "={{ $json.mensaje_id }}",
    "additionalFields": {"disable_notification": True}},
    [1800, 1320], {"telegramApi": TG},
    {"onError": "continueRegularOutput"})
w.link("PanelGuardar", "PanelFijar")

# --- Editar el panel existente ---
panel_switch("PanelCuantasEd", [1200, 1000])
w.link("PanelEditar?", "PanelCuantasEd", 0)

for k in range(PANEL_FILAS + 1):
    params = {
        "operation": "editMessageText",
        "messageType": "message",
        "chatId": "={{ $json.chat_id }}",
        "messageId": "={{ $json.mensaje_id }}",
        "text": "={{ $json.texto }}",
        "additionalFields": {"appendAttribution": False, "parse_mode": "HTML"}}
    params.update(teclado_literal(k))
    w.node(f"PanelEditar{k}", "n8n-nodes-base.telegram", 1.2, params,
           [1400, 860 + k * 110], {"telegramApi": TG},
           {"onError": "continueErrorOutput",
            "retryOnFail": True, "maxTries": 2, "waitBetweenTries": 1000})
    w.link("PanelCuantasEd", f"PanelEditar{k}", k)
    w.link(f"PanelEditar{k}", "PanelEdFallo?", 1)

# Editar falla por dos motivos que no son fallos: "not modified" (el contador no
# cambió entre dos archivos) y el mensaje borrado o vencido a las 48 h. El
# primero se descarta; el segundo cae a crear uno nuevo, y como PanelGuardar
# pisa el id, el panel se muda solo sin dejar dos.
w.if_("PanelEdFallo?",
      "={{ !String($json.error?.message ?? $json.error ?? '').includes('not modified') }}",
      [1620, 1000])
w.link("PanelEdFallo?", "PanelCuantas", 0)

# --- Rama documento (si viene binario y alguna respuesta lo pide) --------------
w.if_("HayDoc?",
      "={{ ($json.respuestas || []).some(r => r.documento) && $binary && Object.keys($binary).length > 0 }}",
      [220, 860])
w.link("Inicio", "HayDoc?")

# El nodo Postgres descarta el binario (igual que en wf_ingesta), por eso va
# ANTES de armar el item con el documento: PrepDoc lo recupera del trigger.
w.pg("CanalDoc",
     "SELECT canal_de_chat(({{ $json.chat_id }})::bigint) AS canal;",
     [400, 860])
w.link("HayDoc?", "CanalDoc", 0)

w.code("PrepDoc", """
const inp = $('Inicio').first().json;
const canal = $input.first().json.canal || 'telegram';
const r = (inp.respuestas || []).find(x => x.documento);
const binKey = Object.keys($('Inicio').first().binary || {})[0];
return [{ json: { chat_id: inp.chat_id, canal, fileName: r?.documento || 'informe.pdf' },
          binary: { data: $('Inicio').first().binary[binKey] } }];
""", [560, 860])
w.link("CanalDoc", "PrepDoc")

w.if_("DocWa?", "={{ $json.canal === 'whatsapp' }}", [720, 860])
w.link("PrepDoc", "DocWa?")

w.node("EnviarDoc", "n8n-nodes-base.telegram", 1.2, {
    "operation": "sendDocument",
    "chatId": "={{ $json.chat_id }}",
    "binaryData": True,
    "binaryPropertyName": "data",
    "additionalFields": {"appendAttribution": False, "parse_mode": "HTML"}}, [900, 920], {"telegramApi": TG},
    {"onError": "continueRegularOutput"})
w.link("DocWa?", "EnviarDoc", 1)

# WhatsApp manda documentos en dos pasos: subir el binario a /media y después
# referenciarlo por id en un mensaje type=document.
w.node("WaSubirDoc", "n8n-nodes-base.httpRequest", 4.2, {
    "method": "POST", "url": f"{GRAPH}/{WA_PNID}/media",
    "authentication": "genericCredentialType", "genericAuthType": "httpHeaderAuth",
    "sendBody": True, "contentType": "multipart-form-data",
    "bodyParameters": {"parameters": [
        {"name": "messaging_product", "value": "whatsapp"},
        {"name": "file", "parameterType": "formBinaryData",
         "inputDataFieldName": "data"}]},
    "options": {"timeout": 60000}}, [900, 800], {"httpHeaderAuth": WA},
    {"onError": "continueRegularOutput"})
w.link("DocWa?", "WaSubirDoc", 0)

w.node("WaMandarDoc", "n8n-nodes-base.httpRequest", 4.2, {
    "method": "POST", "url": f"{GRAPH}/{WA_PNID}/messages",
    "authentication": "genericCredentialType", "genericAuthType": "httpHeaderAuth",
    "sendBody": True, "specifyBody": "json",
    "jsonBody": "={{ JSON.stringify({ messaging_product: 'whatsapp', "
                "to: String($('PrepDoc').first().json.chat_id), type: 'document', "
                "document: { id: $json.id, "
                "filename: $('PrepDoc').first().json.fileName } }) }}",
    "options": {"timeout": 30000}}, [1100, 800], {"httpHeaderAuth": WA},
    {"onError": "continueRegularOutput"})
w.link("WaSubirDoc", "WaMandarDoc")

w.dump("workflows/wf_enviar.json")
