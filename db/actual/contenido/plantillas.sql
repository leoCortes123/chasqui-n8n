




INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('ingesta.parcial', 'telegram', '⚠️ Procesé {{ok}} de {{total}} archivos. Revisa <b>{{fallidos}}</b> y vuelve a enviarlos si quieres incluirlos.', 'html', '["ok", "total", "fallidos"]', 3, true, '[[{"dato": "/listo", "texto": "📊 Analizar"}], [{"dato": "/cancelar", "texto": "✖️ Cancelar"}]]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('sistema.bienvenida', 'telegram', '¡Hola! 👋 Soy <b>Chasqui</b>, un asistente para tu negocio.

Contame qué tenés en mente y te ayudo con lo que sepa. Y si preferís, puedo revisar tus números y decirte dónde estás ganando, dónde se te está yendo la plata y qué conviene hacer esta semana.', 'html', '[]', 5, true, '[[{"dato": "mod:negocio", "texto": "🔎 ¿Qué puedo hacer?"}]]', '[]', true);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('ejecucion.en_curso', 'telegram', '⏳ Estoy analizando tu información. Te aviso apenas esté el informe.', 'html', '[]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('ingesta.formato_nuevo', 'telegram', '🔍 <b>{{nombre_archivo}}</b> viene en un formato que no conocía. Lo estudié y aprendí a leerlo: {{filas}} registros{{rango}}, {{total}} en total.

Si algún número te parece raro, avisame y lo reviso antes de analizar.', 'html', '["nombre_archivo", "filas", "rango", "total"]', 3, true, '[[{"dato": "/listo", "texto": "📊 Analizar"}], [{"dato": "/cancelar", "texto": "✖️ Cancelar"}]]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('ingesta.pedir_columnas', 'telegram', '🤔 Abrí <b>{{nombre_archivo}}</b> pero no encontré las columnas que necesito.

{{motivo}}

Necesito por lo menos una columna con la <b>fecha</b> y una con el <b>valor</b>. Si el archivo tiene títulos o filas en blanco arriba de los encabezados, mandámelo empezando por la fila de encabezados.', 'html', '["nombre_archivo", "motivo"]', 3, true, '[[{"dato": "/listo", "texto": "📊 Analizar"}], [{"dato": "/cancelar", "texto": "✖️ Cancelar"}]]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('sistema.servicio_no_reconocido', 'telegram', 'No reconocí ese servicio. Escribe el nombre tal como aparece en la lista, por favor.', 'html', '[]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('ejecucion.bloqueada_cupo', 'telegram', '🚧 Tu negocio superó el cupo mensual de análisis ({{limite}}). Se renueva el {{renovacion}}.', 'html', '["limite", "renovacion"]', 2, true, '[[{"dato": "/nueva", "texto": "🔄 Intentar de nuevo"}]]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('ejecucion.fallida', 'telegram', '😕 Algo salió mal generando tu informe. Ya quedé avisado y lo reviso. Puedes intentar de nuevo en un rato.', 'html', '[]', 2, true, '[[{"dato": "/nueva", "texto": "🔄 Intentar de nuevo"}]]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('sistema.sin_sesion', 'telegram', 'No tenés ningún análisis en curso.', 'html', '[]', 4, true, '[[{"dato": "/nueva", "texto": "🚀 Empezar análisis"}], [{"dato": "/comofunciona", "texto": "❓ Cómo funciona"}]]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('sistema.no_entendido', 'telegram', 'No te entendí. Tocá un botón y seguimos.', 'html', '[]', 4, true, '[[{"dato": "/nueva", "texto": "🚀 Empezar análisis"}], [{"dato": "/comofunciona", "texto": "❓ Cómo funciona"}]]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('sistema.sin_documentos', 'telegram', 'Todavía no recibí ningún archivo que pueda leer. Mandame al menos uno.', 'html', '[]', 4, true, '[[{"dato": "/cancelar", "texto": "✖️ Cancelar"}]]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('sistema.esperando_listo', 'telegram', 'Recibido. Seguí enviando archivos, o tocá <b>Analizar</b> cuando termines.', 'html', '[]', 4, true, '[[{"dato": "/listo", "texto": "📊 Analizar"}], [{"dato": "/cancelar", "texto": "✖️ Cancelar"}]]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('ingesta.error_archivo', 'telegram', '❌ No pude usar <b>{{nombre_archivo}}</b>.

{{motivo}}

El resto de los archivos sigue en pie: mandalo corregido, seguí con los demás, o analizá con lo que ya tengo.', 'html', '["nombre_archivo", "motivo"]', 5, true, '[[{"dato": "/listo", "texto": "📊 Analizar"}], [{"dato": "/cancelar", "texto": "✖️ Cancelar"}]]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('sesion.cancelada', 'telegram', 'Listo, cancelé ese análisis. Los archivos que ya me mandaste quedan guardados.', 'html', '[]', 1, true, '[[{"dato": "/nueva", "texto": "🚀 Empezar de nuevo"}]]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('sistema.servicio_ya_elegido', 'telegram', 'Ese análisis ya está en curso: <b>{{servicio}}</b>. Seguí mandando archivos o tocá <b>Analizar</b>.', 'html', '["servicio"]', 1, true, '[[{"dato": "/listo", "texto": "📊 Analizar"}], [{"dato": "/cancelar", "texto": "✖️ Cancelar"}]]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('sistema.archivo_sin_sesion', 'telegram', 'Recibí tu archivo y abrí un análisis de <b>{{servicio}}</b> con él. Si querías otra cosa, cancelá y elegimos de nuevo.', 'html', '["servicio"]', 1, true, '[[{"dato": "/listo", "texto": "📊 Analizar"}], [{"dato": "/cancelar", "texto": "✖️ Cancelar"}]]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('sesion.recordatorio', 'telegram', 'Dejaste un análisis a medias y ya lo cerré por inactividad. Los archivos que me mandaste siguen guardados: si querés, arrancamos uno nuevo.', 'html', '[]', 3, true, '[[{"dato": "/nueva", "texto": "🚀 Empezar análisis"}], [{"dato": "/comofunciona", "texto": "❓ Cómo funciona"}]]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.encabezado', 'telegram', '📊 <b>{{servicio}}</b>
<i>{{periodo}}</i>

{{metricas}}', 'html', '["servicio", "periodo", "metricas"]', 1, true, '[]', '["metricas"]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.metrica', 'telegram', '{{icono}} {{etiqueta}}: <b>{{valor}}</b>', 'html', '["icono", "etiqueta", "valor"]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.titular', 'telegram', '<b>{{titular}}</b>', 'html', '["titular"]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.seccion', 'telegram', '{{icono}} <b>{{titulo}}</b>
{{puntos}}', 'html', '["icono", "titulo", "puntos"]', 1, true, '[]', '["puntos"]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.punto', 'telegram', '• {{texto}}', 'html', '["texto"]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.acciones', 'telegram', '✅ <b>Qué hacer esta semana</b>
{{puntos}}', 'html', '["puntos"]', 1, true, '[]', '["puntos"]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.accion', 'telegram', '{{n}}. {{texto}}', 'html', '["n", "texto"]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.sin_narracion', 'telegram', '<i>Nota: no pude verificar el texto del análisis, así que va la lista seca de lo que encontré.</i>', 'html', '[]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('ejecucion.ya_en_curso', 'telegram', '⏳ Ya estoy trabajando en tu informe. Aguantame un momento, te aviso acá mismo.

Si me mandás archivos ahora los guardo igual y te aviso cuando termine.', 'html', '[]', 3, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('ejecucion.informe_parte', 'telegram', '{{texto}}', 'html', '["texto"]', 2, true, '[]', '["texto"]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.encabezado.consulta', 'telegram', '💬 <b>{{servicio}}</b>
<i>{{periodo}}</i>', 'html', '["servicio", "periodo"]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('consulta.pensando', 'telegram', '🔎 Dejame ver qué tengo sobre eso...', 'html', '[]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('sistema.elegir_servicio', 'telegram', '¿Qué análisis necesitás?', 'html', '[]', 2, true, '[]', '[]', true);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.pie', 'telegram', '<i>Las cifras y los cálculos salen de los archivos que me mandaste. Si alguna no te cuadra, decime y la reviso.</i>', 'html', '[]', 2, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('falla.aviso_admin', 'telegram', '⚠️ Falla en <b>{{workflow}}</b> ({{tipo}})

<code>{{mensaje}}</code>', 'html', '[]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('recomendacion.ignorada', 'telegram', '⏭️ Entendido, saco <b>{{titulo}}</b> de la lista.

Si el problema vuelve a aparecer en tus números te lo digo de nuevo, pero no insisto con este.', 'html', '[]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('ejecucion.entregada', 'telegram', '{{texto}}

——————————
⚠️ <b>Análisis hecho con IA.</b> Estas cifras y recomendaciones salen de leer con inteligencia artificial los archivos que me mandaste: <b>pueden tener errores</b>. No son contabilidad certificada ni asesoría financiera o tributaria, y no reemplazan a tu contador. Antes de mover plata, contrastá con tus soportes.', 'html', '["texto"]', 5, true, '[[{"dato": "rec:list", "texto": "✅ Ya hice algo"}]]', '["texto"]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('consulta.sin_datos', 'telegram', '🤔 Todavía no tengo con qué responderte eso.

Mandame tus archivos de ventas o tus facturas de compra y desde ahí te contesto con tus propios números. Si es algo que solo sabés vos —un horario, una condición con un proveedor— enseñámelo con <code>/saber</code> y lo recuerdo.', 'html', '[]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.pie.consulta', 'telegram', '<i>Esto sale de tus propios números y de lo que me hayas enseñado. Si algo no cuadra, revisá los archivos que cargaste o enseñame el dato con <code>/saber</code>.</i>', 'html', '[]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('sistema.como_funciona', 'telegram', 'Son tres pasos:

<b>1.</b> Me mandás tus archivos de ventas y compras, como los exporte tu sistema: Excel, CSV o las facturas XML de la DIAN.
<b>2.</b> Yo leo las columnas y entiendo la estructura sola. Si el formato es nuevo, lo aprendo.
<b>3.</b> Te devuelvo acá mismo un informe con lo que hay que revisar esta semana.

Nada de plantillas ni de formatear archivos: mandá lo que ya tenés.', 'html', '[]', 2, true, '[[{"dato": "/ayuda", "texto": "⬅️ Volver al inicio"}]]', '[]', true);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('conocimiento.guardado', 'telegram', '✅ Anotado: <b>{{titulo}}</b>

Ya te lo puedo responder cuando lo preguntes.', 'html', '["titulo"]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('conocimiento.saber_vacio', 'telegram', 'Escribime qué querés que aprenda después del comando. Por ejemplo:
<code>/saber El bulto de cemento cuesta 32000</code>', 'html', '[]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.titular_seco', 'telegram', 'Esto es lo que encontré en tus números', 'html', '[]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.titular_seco.consulta', 'telegram', 'Esto es lo que tengo cargado sobre eso', 'html', '[]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('portal.enlace', 'telegram', '🔐 <a href="{{url}}">Abrí tu portal</a>

El enlace sirve <b>una sola vez</b> y vence en 15 minutos. Si se te vence, pedime otro con /portal.', 'html', '["url"]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('portal.sin_url', 'telegram', 'Todavía no tengo configurada la dirección del portal. Avisale a soporte.', 'html', '[]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('ingesta.ok', 'telegram', '✅ Leí *{{nombre_archivo}}*: {{filas}} registros{{rango}}, {{productos}} productos, {{total}} en total.{{aviso_sin_resolver}}{{aviso_nit}}

Seguí enviando archivos o escribí */listo* cuando termines.', 'html', '["nombre_archivo", "filas", "rango", "productos", "total", "aviso_sin_resolver", "aviso_nit"]', 6, true, '[[{"dato": "/listo", "texto": "📊 Analizar"}], [{"dato": "/cancelar", "texto": "✖️ Cancelar"}]]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('plan.estado', 'telegram', '📦 Tu plan: <b>{{plan}}</b>

Este mes: {{ejecuciones}} informes · {{tokens}} de {{cupo}} palabras procesadas ({{pct}}%).{{aviso_cupo}}{{aviso_pago}}', 'html', '["plan", "ejecuciones", "tokens", "cupo", "pct", "aviso_cupo"]', 2, true, '[]', '["aviso_pago"]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('ingesta.todos_archivos', 'telegram', '¿Ya me mandaste todos los archivos?', 'markdown', '[]', 1, true, '[[{"dato": "/todos", "texto": "✅ Sí, son todos"}], [{"dato": "/faltan", "texto": "➕ Voy a mandar más"}]]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('ingesta.esperando_mas', 'telegram', 'Dale, espero los que faltan.', 'markdown', '[]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.titular_seco.mercado_compras', 'telegram', 'Esto es lo que encontré en tus compras', 'html', '[]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('ingesta.resumen_sesion', 'telegram', 'Esto fue lo que cargué:

{{detalle}}

Total: {{total}}{{periodo}}{{aviso_nit}}{{aviso_plan}}', 'markdown', '["archivos", "detalle", "total", "aviso_nit", "aviso_plan"]', 3, true, '[[{"dato": "/listo", "texto": "📊 Generar informe"}], [{"dato": "/cancelar", "texto": "✖️ Cancelar"}]]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.salud', 'telegram', '🩺 <b>Salud del negocio</b>
{{lineas}}

<b>Índice general: {{indice}}/100</b>', 'html', '["lineas", "indice"]', 1, true, '[]', '["lineas"]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.salud_linea', 'telegram', '{{semaforo}} {{etiqueta}} <code>{{barra}}</code> {{valor}}', 'html', '["semaforo", "etiqueta", "barra", "valor"]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.hallazgo_titulo', 'telegram', '{{icono}} <b>{{titulo}}</b>', 'html', '["icono", "titulo"]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.hallazgo_problema', 'telegram', '{{texto}}', 'html', '["texto"]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.hallazgo_impacto', 'telegram', '💸 <b>{{texto}}</b>', 'html', '["texto"]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.opcion', 'telegram', '✓ {{texto}}', 'html', '["texto"]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.hallazgo_prioridad', 'telegram', '{{semaforo}} Prioridad {{nivel}}', 'html', '["semaforo", "nivel"]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('ejecucion.entregada.consulta', 'telegram', '{{texto}}

<i>⚠️ Respuesta generada con IA a partir de tus datos: puede equivocarse. Verificá antes de decidir.</i>', 'html', '["texto"]', 2, true, '[[{"dato": "/saber", "texto": "➕ Enseñarme algo"}], [{"dato": "/nueva", "texto": "📊 Analizar mis archivos"}]]', '["texto"]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('mercado.datos_previos', 'telegram', 'Ya tengo compras tuyas cargadas: {{documentos}} documento(s), {{productos}} productos, {{gasto}} en total{{rango}}.

¿Genero el informe de mercado con eso, o cargás facturas nuevas primero?', 'html', '["documentos", "productos", "gasto", "rango"]', 1, true, '[[{"dato": "/listo", "texto": "🛒 Generar con lo que tengo"}], [{"dato": "/faltan", "texto": "➕ Cargar más facturas"}], [{"dato": "/cancelar", "texto": "✖️ Cancelar"}]]', '[]', true);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('mercado.pedir_facturas', 'telegram', 'Listo: <b>Mercado de compras</b>.

Para este informe necesito tus <b>facturas de compra</b>: los XML de la DIAN que te mandan tus proveedores, o el archivo de compras que exporte tu sistema (Excel o CSV). Mandámelos acá.', 'html', '[]', 1, true, '[[{"dato": "/cancelar", "texto": "✖️ Cancelar"}]]', '[]', true);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('sistema.modulo', 'telegram', '{{titular}}', 'html', '["titular"]', 1, true, '[]', '["titular"]', true);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('sistema.modulo_ayuda', 'telegram', '{{ayuda}}', 'html', '["ayuda"]', 1, true, '[]', '["ayuda"]', true);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('sistema.pedir_tipo', 'telegram', 'Antes de arrancar, contame: ¿qué tipo de negocio es?

Lo necesito para leer bien tus números —lo que en un negocio es un margen normal, en otro es una alarma—.', 'html', '[]', 1, true, '[]', '[]', true);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('ingesta.error_no_soportado', 'telegram', '❌ No pude usar <b>{{nombre_archivo}}</b>.

No reconocí el formato de ese archivo.{{detalle}}

Mandámelo en Excel, CSV, o como XML de la DIAN. El resto de los archivos sigue en pie.', 'html', '[]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('ingesta.error_descarga', 'telegram', '❌ No pude bajar <b>{{nombre_archivo}}</b> del chat.

Puede haber sido un problema momentáneo: volvé a mandarlo y sigo desde ahí.', 'html', '[]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('ingesta.error_guardando', 'telegram', '❌ Se me cayó guardando <b>{{nombre_archivo}}</b>.{{detalle}}

No es culpa tuya ni del archivo. Volvé a mandarlo en un rato; si sigue pasando, avisame.', 'html', '[]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('recomendacion.precio_aplicado', 'telegram', '💲 Guardé <b>{{precio}}</b> como precio de <b>{{titulo}}</b>.

Queda en tu lista de precios del portal. Ojo: yo no cambio el precio en tu punto de venta — eso lo hacés vos.', 'html', '[]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('recomendacion.no_encontrada', 'telegram', '🤔 Esa ya no está pendiente: o la cerraste antes, o el problema se resolvió solo.', 'html', '[]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('recomendacion.sin_precio', 'telegram', '🤔 Esa recomendación no tiene un precio para aplicar.', 'html', '[]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('alerta.hallazgo', 'telegram', '🔔 <b>Miré lo último que cargaste</b>

{{icono}} <b>{{titulo}}</b>
{{problema}}

{{impacto}}', 'html', '[]', 1, true, '[[{"dato": "/nueva", "texto": "📊 Ver el análisis completo"}], [{"dato": "rec:list", "texto": "✅ Ya hice algo"}]]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.periodico_aviso', 'telegram', '📅 <b>Pasó un mes desde tu último análisis</b>

Desde entonces cargaste {{movimientos}} movimientos nuevos, así que te preparo el resumen y te lo mando acá en un momento. Esta vez además lo comparo con cómo venías.

Si preferís que no te los mande solo, decímelo y lo apago.', 'html', '[]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.salud_etiqueta.liquidez', 'telegram', 'Liquidez', 'texto', '[]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('sistema.privacidad', 'telegram', 'Uso solo lo que me mandás vos:

• Los archivos quedan guardados en la base de tu negocio, para poder comparar un mes contra otro.
• Al análisis solo van los <b>nombres de las columnas</b> y unas filas de muestra cuando tengo que entender un formato nuevo. Las cifras se procesan acá, no salen.
• No comparto tus datos con otros negocios ni los uso para nada más.
• Cuando quieras que borre todo, pedímelo y lo borro.', 'html', '[]', 2, true, '[[{"dato": "/ayuda", "texto": "⬅️ Volver al inicio"}]]', '[]', true);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('recomendacion.lista', 'telegram', '📋 <b>Lo que te vengo diciendo</b>

Tocá lo que ya hayas hecho y lo cierro. Lo que no aplique a tu negocio también se puede sacar de la lista.', 'html', '[]', 1, true, '[]', '[]', true);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('recomendacion.sin_pendientes', 'telegram', '✨ No tenés nada pendiente ahora mismo.

Cuando analice tus próximos archivos y encuentre algo, te lo digo por acá.', 'html', '[]', 1, true, '[]', '[]', true);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('recomendacion.detalle', 'telegram', '{{icono}} <b>{{titulo}}</b>

{{problema}}

{{impacto}}

<i>Te lo vengo diciendo desde hace {{dias}} días.</i>', 'html', '[]', 1, true, '[]', '[]', true);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('sistema.pedir_archivos', 'telegram', 'Listo: <b>{{servicio}}</b>.

Mandame los archivos de <b>facturación</b> de tu negocio: las <b>ventas</b> y las <b>compras</b>. De dónde salgan no me importa —lo que exporte tu sistema, lo que te pase el contador, un Excel que llevés a mano— y tampoco cómo se llamen las columnas: yo los leo.

📎 Me sirven archivos {{formatos}}.

📅 <b>Cuánta historia mandarme:</b> con <b>3 meses</b> ya sale un análisis serio. Entre más me mandes, mejor: las tendencias de costo y lo que rota lento no se ven en dos semanas.

Mandalos todos de una: los voy contando en un mensaje que dejo fijado arriba, y ahí mismo vas a tener el botón para analizar cuando termines.', 'html', '["servicio", "formatos"]', 9, true, '[[{"dato": "/cancelar", "texto": "✖️ Cancelar"}]]', '[]', true);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('recomendacion.hecha', 'telegram', '✅ Listo, cierro <b>{{titulo}}</b>.

Lo voy a revisar en el próximo análisis: si los números lo confirman, mejor todavía.', 'html', '[]', 1, true, '[]', '[]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('sistema.consentimiento', 'telegram', 'Antes de arrancar, dos cosas claras. 👇

<b>Qué hago por vos</b>
Soy tu asistente de negocio. No soy un programa donde tenés que meter datos: me mandás lo que ya tenés y yo trabajo con eso.

• 📊 <b>Te leo los números</b> y te digo qué te deja plata, qué te la está quitando y a qué producto le subió el costo.
• 💰 <b>Cobranzas:</b> llevo quién te debe, cuánto y desde cuándo, y te aviso a quién toca cobrarle esta semana.
• ⏰ <b>Recordatorios:</b> lo que hay que pagar, pedir o revisar, en el momento en que sirve acordarse.
• 🔔 <b>Alertas:</b> se te está agotando algo que rota, un proveedor te subió el precio, un cliente se atrasó más de lo normal.
• 🧭 <b>Recomendaciones:</b> en qué conviene gastar primero y qué decisión tiene más efecto esta semana.
• 💬 <b>Preguntame lo que sea</b> de tu negocio y te contesto con tus propios datos.

<b>⚠️ Importante: esto lo hace una inteligencia artificial</b>
Todo lo que te entrego —informes, cifras, alertas y recomendaciones— es el <b>resultado de un análisis hecho con IA</b> sobre los archivos que vos me mandes. <b>Puede equivocarse.</b> No es contabilidad certificada ni asesoría legal, financiera o tributaria, y <b>no reemplaza a tu contador</b>. Antes de tomar una decisión de plata, contrastá con tus soportes. Las decisiones de tu negocio son tuyas.

<b>🔐 Tus datos</b>
Los uso solo para trabajar para vos: quedan guardados en tu negocio, no se comparten con nadie ni se usan para otra cosa, y los borro el día que me lo pidas. Escribí /privacidad para el detalle.

<b>🎁 Plan gratuito</b>
Podés cargar hasta <b>{{meses}} meses</b> de historia. Lo más viejo que eso no lo guardo. Para trabajar con toda tu historia y tener las alertas y los recordatorios andando todo el mes, se necesita el servicio completo (/plan).

¿Arrancamos?', 'html', '["meses"]', 1, true, '[]', '[]', true);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('carga.panel', 'telegram', '📥 Llevo <b>{{archivos}}</b> {{palabra_archivo}} cargados.
{{detalle}}{{avisos}}
✅ <b>Cuando termines de mandarlos todos, tocá 📊 Analizar.</b>', 'html', '["archivos", "palabra_archivo", "detalle", "avisos"]', 2, true, '[[{"dato": "/listo", "texto": "📊 Analizar"}], [{"dato": "/cancelar", "texto": "✖️ Cancelar"}]]', '["detalle", "avisos"]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('carga.panel_esperando', 'telegram', '⏳ <b>Esperando a que terminen de llegar tus archivos…</b>
{{detalle}}{{avisos}}
Arranco solo cuando dejen de entrar. No mandes nada más si ya terminaste.', 'html', '["archivos", "palabra_archivo", "detalle", "avisos"]', 2, true, '[[{"dato": "/cancelar", "texto": "✖️ Cancelar"}]]', '["detalle", "avisos"]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('carga.panel_analizando', 'telegram', '🔍 <b>Analizando {{archivos}} {{palabra_archivo}}…</b>
{{detalle}}
Te aviso acá mismo en cuanto esté.', 'html', '["archivos", "palabra_archivo", "detalle"]', 2, true, '[]', '["detalle"]', false);
INSERT INTO public.plantillas (clave, canal, cuerpo, formato, variables, version, activo, teclado, crudas, reemplaza) VALUES ('informe.base', 'telegram', '🧮 <b>Sobre qué calculé esto</b>
{{lineas}}', 'html', '["lineas"]', 2, true, '[]', '["lineas"]', false);




