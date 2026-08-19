#!/usr/bin/env python3
"""wf_ingesta — descarga el archivo de Telegram, lo guarda en bytea y lo lleva a
movimientos. Un archivo malo marca solo su documento en error, la sesión sigue viva.

La ingesta tabular ya no asume un esquema fijo. Cadena:

  Registrar (¿documento o tabla?)
    documento -> Procesar (Postgres parsea el bytea: DIAN XML)
    tabla     -> Extraer (csv/xls/xlsx/ods) -> Identificar por huella de cabeceras
                   huella conocida -> Cargar
                   huella nueva    -> DeepSeek infiere el mapeo -> se persiste
                                      como fila -> Cargar

El LLM solo ve los nombres de las columnas y unas filas de muestra: infiere el
mapeo, nunca las cifras. Las cifras las carga Postgres con ese mapeo.
"""
import os, sys
from wf_lib import WF, PG, TG, DS, WA, GRAPH, LLM_URL

WA_PNID = os.environ.get("WA_PHONE_NUMBER_ID", "")
if not WA_PNID:
    print("aviso: WA_PHONE_NUMBER_ID vacío; la descarga por WhatsApp queda "
          "generada pero no funcional", file=sys.stderr)

w = WF("wfIngesta00000000001", "wf_ingesta")

w.node("Inicio", "n8n-nodes-base.executeWorkflowTrigger", 1.1,
       {"inputSource": "passthrough"}, [0, 400])

# El file_id de Telegram y el media id de WhatsApp viajan en el mismo campo del
# evento; el canal decide cómo se baja el binario.
w.if_("DeWa?", "={{ $json.evento?.canal === 'whatsapp' }}", [140, 400])
w.link("Inicio", "DeWa?")

# Descarga el binario del archivo desde Telegram (resource file + fileId).
w.node("BajarArchivo", "n8n-nodes-base.telegram", 1.2, {
    "resource": "file",
    "fileId": "={{ $json.evento.file_id }}",
    "additionalFields": {}}, [280, 460], {"telegramApi": TG},
    # Con 101 archivos en 28 segundos, un hipo de la API de Telegram no puede
    # costar un archivo: se reintenta antes de darlo por perdido, y solo si
    # después de tres intentos no baja se le pide al usuario que lo reenvíe.
    {"onError": "continueErrorOutput",
     "retryOnFail": True, "maxTries": 3, "waitBetweenTries": 2000})
w.link("DeWa?", "BajarArchivo", 1)

# WhatsApp baja en dos pasos: el media id da una URL firmada y efímera, y esa
# URL exige el MISMO Bearer (sin él responde 404, no 401: pasó).
w.node("WaUrlArchivo", "n8n-nodes-base.httpRequest", 4.2, {
    "method": "GET", "url": f"={{{{ '{GRAPH}/' + $json.evento.file_id }}}}",
    "authentication": "genericCredentialType", "genericAuthType": "httpHeaderAuth",
    "options": {"timeout": 30000}}, [280, 280], {"httpHeaderAuth": WA},
    {"onError": "continueErrorOutput"})
w.link("DeWa?", "WaUrlArchivo", 0)

w.node("WaBajarArchivo", "n8n-nodes-base.httpRequest", 4.2, {
    "method": "GET", "url": "={{ $json.url }}",
    "authentication": "genericCredentialType", "genericAuthType": "httpHeaderAuth",
    "options": {"timeout": 60000,
                "response": {"response": {"responseFormat": "file",
                                          "outputPropertyName": "data"}}}},
    [440, 280], {"httpHeaderAuth": WA},
    {"onError": "continueErrorOutput"})
w.link("WaUrlArchivo", "WaBajarArchivo")

# Binario -> base64 + metadatos de la sesión. Conserva el binario: la rama
# tabular lo necesita de vuelta más adelante.
w.code("Empaquetar", """
const ev = $('Inicio').first().json.evento;
const sesion_id = $('Inicio').first().json.sesion_id ?? ev.sesion_id;
const buf = await this.helpers.getBinaryDataBuffer(0, 'data');
return [{ json: {
  sesion_id,
  nombre: ev.file_name || 'archivo',
  mime: ev.mime || 'application/octet-stream',
  b64: buf.toString('base64'),
  chat_id: $('Inicio').first().json.chat_id
}, binary: $input.first().binary }];
""", [620, 400])
w.link("BajarArchivo", "Empaquetar")
w.link("WaBajarArchivo", "Empaquetar")

# Registra el documento (idempotente por hash) y decide la clase.
w.pg("Registrar",
     "SELECT ingesta_registrar_documento("
     "({{ $json.sesion_id }})::bigint, "
     "(SELECT negocio_id FROM sesiones WHERE id=({{ $json.sesion_id }})::bigint), "
     "'{{ String($json.nombre).replaceAll(\"'\",\"''\") }}', "
     "'{{ $json.mime }}', "
     "decode('{{ $json.b64 }}','base64')) AS reg;",
     [600, 400], extra={"onError": "continueErrorOutput"})
w.link("Empaquetar", "Registrar")

# ¿Sabemos leer este tipo de archivo? Si no, el motivo ya quedó en documentos.
w.if_("Reconocido?", "={{ $json.reg.reconocido === true }}", [800, 400])
w.link("Registrar", "Reconocido?")

# ¿Hace falta que n8n extraiga la tabla antes de cargar?
w.if_("RequiereTabla?", "={{ $json.reg.requiere_tabla === true }}", [1000, 400])
w.link("Reconocido?", "RequiereTabla?", 0)   # true

# --- Rama documento: Postgres parsea el bytea (DIAN XML) ----------------------
w.pg("Procesar",
     "SELECT ingesta_procesar_documento( "
     "({{ $json.reg.documento_id }})::bigint ) AS res, "
     "({{ $json.reg.documento_id }})::bigint AS documento_id;",
     [1200, 620])
w.link("RequiereTabla?", "Procesar", 1)      # false

# --- Rama tabular ------------------------------------------------------------
# Los nodos Postgres descartan el binario: sus items solo llevan json. Sin esto
# el nodo de extracción recibe items sin 'data' y falla con
# "expects the node's input data to contain a binary file 'data'".
w.code("RecuperarBinario", """
return [{ json: { ...$input.first().json,
                  operacion: $('Registrar').first().json.reg.operacion },
          binary: $('Empaquetar').first().binary }];
""", [1200, 180])
w.link("RequiereTabla?", "RecuperarBinario", 0)   # true

w.if_("EsCSV?", "={{ $json.operacion === 'csv' }}", [1400, 180])
w.link("RecuperarBinario", "EsCSV?")

# El delimitador no se adivina: se detecta contando en la primera línea.
# Sin esto, un CSV con ';' entra como una sola columna, la huella no matchea
# y la inferencia recibe basura.
w.code("DetectarSeparador", """
const item = $input.first();
const buf = await this.helpers.getBinaryDataBuffer(0, 'data');
const linea = buf.toString('utf8').replace(/^\\uFEFF/, '').split(/\\r?\\n/)[0] ?? '';
let delim = ',', max = 0;
for (const c of [',', ';', '\\t', '|']) {
  const n = linea.split(c).length - 1;
  if (n > max) { max = n; delim = c; }
}
return [{ json: { ...item.json, delim }, binary: item.binary }];
""", [1500, 60])
w.link("EsCSV?", "DetectarSeparador", 0)

w.node("ExtraerCSV", "n8n-nodes-base.extractFromFile", 1, {
    "operation": "csv",
    "binaryPropertyName": "data",
    "options": {"headerRow": True, "enableBOM": True,
                "delimiter": "={{ $json.delim }}",
                "relaxQuotes": True, "skipRecordsWithErrors": True}},
    [1650, 60])
w.link("DetectarSeparador", "ExtraerCSV")

# xlsx/xls/ods: SheetJS detecta el formato real del buffer, así que un solo
# nodo cubre los tres.
w.node("ExtraerHoja", "n8n-nodes-base.extractFromFile", 1, {
    "operation": "xlsx",
    "binaryPropertyName": "data",
    "options": {"headerRow": True, "includeEmptyCells": False}},
    [1600, 300])
w.link("EsCSV?", "ExtraerHoja", 1)

# Un item por fila -> array + cabeceras + dos muestras.
#
# Son DOS y no una a propósito. `muestra` (5 filas) es la que va al prompt si al
# final hay que llamar al modelo. `muestra_amplia` (100) es la que mira Postgres
# para deducir el formato de fecha y los separadores: con 5 filas de un archivo
# que empieza el día 3 no aparece ningún día > 12 y DD/MM vs MM/DD queda
# indecidible. Con 100 aparece casi siempre, y cuando no, el default latino es
# el mismo que declaraba el prompt.
w.code("AgruparFilas", """
const filas = $input.all().map(i => i.json).filter(f => f && Object.keys(f).length);
const docId = $('Registrar').first().json.reg.documento_id;
// Las cabeceras son la unión de las claves: una fila suelta puede venir corta.
const cols = [];
for (const f of filas) for (const k of Object.keys(f)) if (!cols.includes(k)) cols.push(k);
return [{ json: { documento_id: docId, columnas: cols, filas,
                  muestra: filas.slice(0, 5),
                  muestra_amplia: filas.slice(0, 100) } }];
""", [1800, 180])
w.link("ExtraerCSV", "AgruparFilas")
w.link("ExtraerHoja", "AgruparFilas")

# Identifica el layout y trae de una el prompt de inferencia, para no gastar un
# nodo extra en el caso raro en que haga falta.
#
# Desde la 073 esta llamada hace mucho más que buscar la huella: si es nueva,
# resuelve el mapeo con el diccionario de sinónimos y solo prende
# `requiere_inferencia` cuando ni la fecha ni el valor se reconocen. Por eso
# ahora recibe la muestra: sin ver datos no se puede deducir el formato de fecha
# ni el separador decimal.
w.pg("Identificar",
     "SELECT ingesta_identificar_tabular( ({{ $json.documento_id }})::bigint, "
     "  ARRAY(SELECT jsonb_array_elements_text("
     "    '{{ JSON.stringify($json.columnas).replaceAll(\"'\",\"''\") }}'::jsonb)), "
     "  '{{ JSON.stringify($json.muestra_amplia).replaceAll(\"'\",\"''\") }}'::jsonb"
     ") AS ident, "
     "(SELECT to_jsonb(p) FROM prompts_tecnicos p "
     "  WHERE p.clave='ingesta.inferir_mapeo' AND p.activo) AS prompt;",
     [2000, 180])
w.link("AgruparFilas", "Identificar")

w.if_("Inferir?", "={{ $json.ident.requiere_inferencia === true }}", [2200, 180])
w.link("Identificar", "Inferir?")

# Arma la petición: solo cabeceras y muestra. Las cifras del archivo completo
# nunca salen de la casa.
w.code("ArmarMapeo", """
const ident = $('Identificar').first().json;
const g = $('AgruparFilas').first().json;
const p = ident.prompt;
const usuario = p.usuario
  .replace('{{columnas}}', JSON.stringify(g.columnas, null, 2))
  .replace('{{muestra}}', JSON.stringify(g.muestra, null, 2));
return [{ json: { documento_id: g.documento_id, columnas: g.columnas,
  body: { model: p.modelo, temperature: Number(p.temperatura),
          max_tokens: p.max_tokens, response_format: { type: 'json_object' },
          messages: [ {role:'system', content:p.sistema},
                      {role:'user', content:usuario} ] } } }];
""", [2400, 60])
w.link("Inferir?", "ArmarMapeo", 0)   # true

w.node("InferirMapeo", "n8n-nodes-base.httpRequest", 4.2, {
    "method": "POST", "url": LLM_URL,
    "authentication": "genericCredentialType", "genericAuthType": "httpHeaderAuth",
    "sendBody": True, "specifyBody": "json",
    "jsonBody": "={{ JSON.stringify($json.body) }}",
    "options": {"timeout": 60000}}, [2600, 60], {"httpHeaderAuth": DS},
    {"onError": "continueRegularOutput", "retryOnFail": True, "maxTries": 2})
w.link("ArmarMapeo", "InferirMapeo")

# El modelo puede devolver el JSON envuelto en ```json: se limpia. Si no se
# puede parsear, se manda {} y la validación de la BD lo rechaza con motivo.
w.code("LeerMapeo", """
const src = $('ArmarMapeo').first().json;
let txt = $input.first().json?.choices?.[0]?.message?.content ?? '';
txt = String(txt).replace(/^\\s*```(?:json)?/i, '').replace(/```\\s*$/, '').trim();
let mapeo;
try { mapeo = JSON.parse(txt); }
catch (e) { mapeo = { error: 'el modelo no devolvió un JSON válido' }; }
return [{ json: { documento_id: src.documento_id, columnas: src.columnas, mapeo } }];
""", [2800, 60])
w.link("InferirMapeo", "LeerMapeo")

# Valida y persiste el formato nuevo. Si el mapeo es inválido, marca el
# documento en error con el motivo y no guarda nada.
w.pg("RegistrarFormato",
     "SELECT ingesta_registrar_formato_inferido( ({{ $json.documento_id }})::bigint, "
     "  ARRAY(SELECT jsonb_array_elements_text("
     "    '{{ JSON.stringify($json.columnas).replaceAll(\"'\",\"''\") }}'::jsonb)), "
     "  '{{ JSON.stringify($json.mapeo).replaceAll(\"'\",\"''\") }}'::jsonb ) AS inferido;",
     [3000, 60])
w.link("LeerMapeo", "RegistrarFormato")

# Carga con el mapeo (conocido o recién aprendido). Las filas se leen de
# AgruparFilas para no arrastrar el payload por toda la cadena.
w.pg("CargarTabular",
     "SELECT ingesta_cargar_tabular( "
     "({{ $('AgruparFilas').first().json.documento_id }})::bigint, "
     "'{{ JSON.stringify($('AgruparFilas').first().json.filas).replaceAll(\"'\",\"''\") }}'::jsonb "
     ") AS res, "
     "({{ $('AgruparFilas').first().json.documento_id }})::bigint AS documento_id;",
     [3200, 180])
w.link("RegistrarFormato", "CargarTabular")
w.link("Inferir?", "CargarTabular", 1)   # false: huella ya conocida

# --- Confluencia: matching + resumen de lo entendido -------------------------
w.pg("Resolver",
     "SELECT match_resolver_documento( ({{ $json.documento_id }})::bigint ) AS m, "
     "ingesta_resumen_documento( ({{ $json.documento_id }})::bigint ) AS r, "
     "({{ $json.documento_id }})::bigint AS documento_id;",
     [3400, 400])
w.link("CargarTabular", "Resolver")
w.link("Procesar", "Resolver")

# --- Confluencia de TODOS los caminos -> el panel (071) ----------------------
# Antes había un mensaje por cada cosa que podía pasarle a un archivo: uno si no
# se pudo bajar, otro si no se sabía leer, otro si el parseo falló. Con 101
# archivos eso es una metralleta, y la metralleta produce la misma desconfianza
# que el error que la 071 vino a arreglar. Ahora todo termina en el mismo lugar:
# el panel, que los cuenta y los nombra en UN mensaje que se edita.
#
# El único camino que sigue necesitando algo aparte es el archivo que no se pudo
# BAJAR: no deja fila en `documentos` —el hash sale del contenido— así que el
# panel no tendría con qué contarlo. Se anota en la sesión y el panel lo nombra
# pidiendo que lo reenvíe. Es el único reenvío que el sistema pide.
w.pg("AnotarNoBajado",
     "SELECT carga_registrar_fallo("
     "({{ $('Inicio').first().json.sesion_id "
     "?? $('Inicio').first().json.evento?.sesion_id }})::bigint, "
     "'{{ String($('Inicio').first().json.evento?.file_name ?? \"\")"
     ".replaceAll(\"'\",\"''\") }}') AS ok;",
     [400, 620], extra={"onError": "continueRegularOutput"})
w.link("BajarArchivo", "AnotarNoBajado", 1)
w.link("WaUrlArchivo", "AnotarNoBajado", 1)
w.link("WaBajarArchivo", "AnotarNoBajado", 1)

# El INSERT del documento también puede reventar (una constraint, la base
# caída). Ese archivo tampoco quedó guardado, así que se anota igual: antes esto
# mandaba un mensaje suelto que se perdía entre los demás.
w.pg("AnotarNoGuardado",
     "SELECT carga_registrar_fallo("
     "({{ $('Empaquetar').first().json.sesion_id }})::bigint, "
     "'{{ String($('Empaquetar').first().json.nombre ?? \"\")"
     ".replaceAll(\"'\",\"''\") }}') AS ok;",
     [600, 620], extra={"onError": "continueRegularOutput"})
w.link("Registrar", "AnotarNoGuardado", 1)

# El archivo que no sabemos leer y el que falló al parsear SÍ tienen fila en
# `documentos` (estado 'error'), así que el panel ya los ve: no hay nada que
# anotar, solo que refrescar.
w.code("Sesion", """
let s = null;
try { s = $('Empaquetar').first().json.sesion_id; } catch (e) {}
if (!s) { const i = $('Inicio').first().json;
          s = i.sesion_id ?? i.evento?.sesion_id ?? null; }
let chat = null;
try { chat = $('Empaquetar').first().json.chat_id; } catch (e) {}
if (!chat) { try { chat = $('Inicio').first().json.chat_id; } catch (e) {} }
return [{ json: { sesion_id: s, chat_id: chat } }];
""", [3800, 400])
w.link("Resolver", "Sesion")
w.link("Reconocido?", "Sesion", 1)      # formato que no sabemos leer
w.link("AnotarNoBajado", "Sesion")
w.link("AnotarNoGuardado", "Sesion")

# --- El debounce ------------------------------------------------------------
# Cada archivo espera y después pregunta qué hacer. La forma es la de la 042; lo
# que cambia es que la decisión ya no vive acá sino en `carga_evaluar`, y que
# entre las respuestas posibles NO está descartar nada.
#
# La espera es un segundo más larga que el silencio que exige la base: si fueran
# iguales, el redondeo de dos relojes distintos haría que el último archivo
# despertara justo antes de cumplirlo y nadie arrancara el análisis.
w.node("Esperar", "n8n-nodes-base.wait", 1.1,
       {"resume": "timeInterval", "amount": 11, "unit": "seconds"}, [4000, 400])
w.link("Sesion", "Esperar")

w.pg("Evaluar",
     "SELECT carga_evaluar(({{ $json.sesion_id }})::bigint) AS ev;",
     [4200, 400])
w.link("Esperar", "Evaluar")

# 'nada' = entró un archivo después que yo y esa ejecución más nueva decide.
w.code("Decidir", """
const ev = $input.first().json.ev || {};
if (!ev.accion || ev.accion === 'nada') return [];
const ctx = $('Sesion').first().json;
return [{ json: {
  accion: ev.accion,
  ejecucion_id: ev.ejecucion_id ?? null,
  chat_id: ev.panel?.chat_id ?? ctx.chat_id,
  panel: { sesion_id: ctx.sesion_id, modo: ev.panel?.modo || 'panel' } } }];
""", [4400, 400])
w.link("Evaluar", "Decidir")

# El panel se refresca SIEMPRE que haya algo que decir, tanto si solo cambió el
# contador como si el análisis arranca: en ese caso pasa a "Analizando…" y pierde
# el botón, que es la señal de que ya no hay que tocar nada.
w.node("PanelEnviar", "n8n-nodes-base.executeWorkflow", 1.2, {
    "workflowId": {"__rl": True, "value": "wfEnviar00000000001", "mode": "id"},
    "workflowInputs": {"mappingMode":"defineBelow","value":{}},
    "options": {}}, [4600, 300], None, {"onError":"continueRegularOutput"})
w.link("Decidir", "PanelEnviar")

w.if_("Analizar?", "={{ $json.accion === 'analizar' }}", [4600, 520])
w.link("Decidir", "Analizar?")

w.code("ArmarEjecutar", """
const j = $input.first().json;
return [{ json: { tipo: 'ejecutar', chat_id: j.chat_id,
                  ejecucion_id: j.ejecucion_id } }];
""", [4800, 520])
w.link("Analizar?", "ArmarEjecutar", 0)

# Se dispara y se suelta. `waitForSubWorkflow: False` no es una optimización:
# es lo único que despega el análisis del reloj de ESTA ejecución.
#
# El reloj de wf_ingesta arranca cuando llega el archivo. Con 101 archivos, el
# último llegó a los 28 segundos, esperó 11 de silencio, y recién ahí empezó un
# análisis que tarda minutos: los 300 segundos de EXECUTIONS_TIMEOUT se
# cumplieron con el informe YA GENERADO y n8n canceló la cadena en `Cerrar`.
# 3.411 caracteres de informe válido a la basura.
#
# Soltándolo, wf_ejecutar corre en su propia ejecución con su propio reloj, y
# entrega él mismo el informe (ver gen_wf_ejecutar.py, nodo EntregarInforme).
w.node("LlamarEjecutar", "n8n-nodes-base.executeWorkflow", 1.2, {
    "workflowId": {"__rl": True, "value": "wfEjecutar000000001", "mode": "id"},
    "workflowInputs": {"mappingMode":"defineBelow","value":{}},
    "options": {"waitForSubWorkflow": False}}, [5000, 520], None,
    {"onError":"continueRegularOutput"})
w.link("ArmarEjecutar", "LlamarEjecutar")

w.dump("workflows/wf_ingesta.json")
