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
    {"onError": "continueErrorOutput"})
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

# Un item por fila -> array + cabeceras + muestra chica para el LLM.
w.code("AgruparFilas", """
const filas = $input.all().map(i => i.json).filter(f => f && Object.keys(f).length);
const docId = $('Registrar').first().json.reg.documento_id;
// Las cabeceras son la unión de las claves: una fila suelta puede venir corta.
const cols = [];
for (const f of filas) for (const k of Object.keys(f)) if (!cols.includes(k)) cols.push(k);
return [{ json: { documento_id: docId, columnas: cols, filas,
                  muestra: filas.slice(0, 5) } }];
""", [1800, 180])
w.link("ExtraerCSV", "AgruparFilas")
w.link("ExtraerHoja", "AgruparFilas")

# Identifica el layout por huella y trae de una el prompt de inferencia, para
# no gastar un nodo extra cuando la huella es nueva.
w.pg("Identificar",
     "SELECT ingesta_identificar_tabular( ({{ $json.documento_id }})::bigint, "
     "  ARRAY(SELECT jsonb_array_elements_text("
     "    '{{ JSON.stringify($json.columnas).replaceAll(\"'\",\"''\") }}'::jsonb))"
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

# El éxito ya no contesta archivo por archivo: la confirmación es una sola,
# cuando el usuario deja de mandar. Los errores sí se avisan al momento.
w.if_("CargoBien?", "={{ $json.r.estado === 'parseado' }}", [3600, 400])
w.link("Resolver", "CargoBien?")

# --- Éxito: debounce -------------------------------------------------------
# Cada archivo espera unos segundos; al despertar pregunta "¿son todos?" solo
# si sigue siendo el último documento de la sesión. Si entró otro mientras
# tanto, esa ejecución más nueva es la que pregunta, y esta se calla.
w.node("Esperar", "n8n-nodes-base.wait", 1.1,
       {"resume": "timeInterval", "amount": 8, "unit": "seconds"}, [3800, 300])
w.link("CargoBien?", "Esperar", 0)

# También se calla si la sesión ya no recibe (el usuario canceló o mandó
# /listo por texto durante la espera).
w.pg("SigueUltimo",
     "SELECT (d.id = (SELECT max(x.id) FROM documentos x WHERE x.sesion_id = d.sesion_id) "
     "        AND s.estado = 'recibiendo' AND s.cerrada_en IS NULL) AS preguntar "
     "FROM documentos d JOIN sesiones s ON s.id = d.sesion_id "
     "WHERE d.id = ({{ $('Resolver').first().json.documento_id }})::bigint;",
     [4000, 300])
w.link("Esperar", "SigueUltimo")

w.if_("Preguntar?", "={{ $json.preguntar === true }}", [4200, 300])
w.link("SigueUltimo", "Preguntar?")

# La respuesta a Sí/No la maneja el router (042): /todos -> resumen único de la
# sesión con Generar informe/Cancelar; /faltan -> seguir esperando.
w.code("Pregunta", """
return [{ json: { chat_id: $('Empaquetar').first().json.chat_id,
  respuestas: [{ plantilla: 'ingesta.todos_archivos', vars: {} }] } }];
""", [4400, 300])
w.link("Preguntar?", "Pregunta", 0)

# --- Falla del archivo: aviso inmediato, ese sí es urgente -------------------
w.code("RespuestaError", """
const r = $('Resolver').first().json.r || {};
return [{ json: { chat_id: $('Empaquetar').first().json.chat_id,
  respuestas: [{ plantilla: 'ingesta.error_archivo',
    vars: { nombre_archivo: r.nombre_archivo || 'archivo',
            motivo: r.error || 'no pude leerlo' } }] } }];
""", [3800, 500])
w.link("CargoBien?", "RespuestaError", 1)

# --- Ramas de error ----------------------------------------------------------
# Archivo que no sabemos leer: el motivo lo escribió ingesta_registrar_documento.
w.code("NoSoportado", """
const reg = $input.first().json.reg || {};
return [{ json: { chat_id: $('Empaquetar').first().json.chat_id,
  respuestas: [{ plantilla:'ingesta.error_archivo',
    vars:{ nombre_archivo: $('Empaquetar').first().json.nombre,
           motivo: reg.error || 'no reconocí el formato' } }] } }];
""", [1000, 620])
w.link("Reconocido?", "NoSoportado", 1)   # false

w.code("ErrorDescarga", """
return [{ json: { chat_id: $('Inicio').first().json.chat_id,
  respuestas: [{ plantilla:'ingesta.error_archivo',
    vars:{ nombre_archivo: $('Inicio').first().json.evento?.file_name || 'archivo',
           motivo:'no pude descargarlo del chat' } }] } }];
""", [400, 620])
# El INSERT del documento también puede reventar (una constraint, la base
# caída). Antes eso mataba la ejecución sin decir nada: el usuario mandaba diez
# archivos, no recibía una sola respuesta, y al tocar Analizar le contestaban
# "no cargaste ninguno". Cualquier archivo que no entre se avisa AHORA.
w.code("ErrorRegistrar", """
const e = $input.first().json.error;
const msg = (e?.message || e || '').toString();
return [{ json: { chat_id: $('Empaquetar').first().json.chat_id,
  respuestas: [{ plantilla:'ingesta.error_archivo',
    vars:{ nombre_archivo: $('Empaquetar').first().json.nombre,
           motivo: 'se me cayó guardándolo (' + msg.slice(0, 120) + ')' } }] } }];
""", [600, 620])
w.link("Registrar", "ErrorRegistrar", 1)

w.link("BajarArchivo", "ErrorDescarga", 1)
w.link("WaUrlArchivo", "ErrorDescarga", 1)
w.link("WaBajarArchivo", "ErrorDescarga", 1)

# Enviar la respuesta por wf_enviar.
w.node("Enviar", "n8n-nodes-base.executeWorkflow", 1.2, {
    "workflowId": {"__rl": True, "value": "wfEnviar00000000001", "mode": "id"},
    "workflowInputs": {"mappingMode":"defineBelow","value":{}},
    "options": {}}, [4600, 400], None, {"onError":"continueRegularOutput"})
w.link("Pregunta", "Enviar")
w.link("RespuestaError", "Enviar")
w.link("NoSoportado", "Enviar")
w.link("ErrorDescarga", "Enviar")
w.link("ErrorRegistrar", "Enviar")

w.dump("workflows/wf_ingesta.json")
