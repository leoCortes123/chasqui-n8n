-- 001_contenido.sql — el comportamiento de Chasqui, que vive en filas.
--
-- GENERADO por bin/gen_base.sh. No editar a mano: se cambia por migración y se
-- regenera.
--
-- Sin esto el sistema arranca, no responde nada y no tiene servicios. No son
-- datos de ejemplo: son el producto. Los datos de negocio (movimientos,
-- documentos, facturas, negocios, usuarios) NO están acá y no deben estarlo.






INSERT INTO public.tipos_negocio (codigo, nombre, orden, activo) VALUES ('minimercado', '🛒 Minimercado o tienda', 10, true);
INSERT INTO public.tipos_negocio (codigo, nombre, orden, activo) VALUES ('almacen', '🏬 Almacén o punto de venta', 20, true);
INSERT INTO public.tipos_negocio (codigo, nombre, orden, activo) VALUES ('distribuidora', '🚚 Distribuidora o mayorista', 30, true);
INSERT INTO public.tipos_negocio (codigo, nombre, orden, activo) VALUES ('restaurante', '🍽️ Restaurante o cafetería', 40, true);
INSERT INTO public.tipos_negocio (codigo, nombre, orden, activo) VALUES ('otro', '🏷️ Otro', 50, true);









INSERT INTO public.modulos (codigo, nombre, titular, ayuda, orden, activo) VALUES ('negocio', '🔎 ¿Qué puedo hacer?', 'Esto es lo que puedo hacer por ahora. Elegí por dónde arrancamos:', '<b>Soy tu asistente de negocio</b>

No sos vos el que trabaja para el sistema: me mandás lo que ya tenés —las facturas de venta y de compra, como las exporte tu programa o te las pase el contador— y de ahí en adelante trabajo yo.

<b>Con eso te ayudo a:</b>

📊 <b>Entender tus números.</b> Qué producto te deja plata y cuál te la quita, a cuál le subió el costo, qué se te está quedando quieto en la bodega.

💰 <b>Cobrar.</b> Quién te debe, cuánto y desde cuándo, y a quién conviene llamar primero esta semana.

⏰ <b>No olvidarte de nada.</b> Lo que hay que pagar, pedir o revisar, avisado cuando todavía sirve.

🔔 <b>Enterarte a tiempo.</b> Se agota algo que rota, un proveedor te subió el precio, un cliente se atrasó más de lo que suele.

🧭 <b>Decidir.</b> No solo el dato: cuánto te está costando cada problema y qué conviene hacer primero.

💬 <b>Contestarte.</b> Preguntame lo que quieras de tu negocio y te respondo con tus propios datos.

Cuanta más historia me des, mejor: con tres meses ya sale un análisis serio.

⚠️ Todo esto lo produce una <b>inteligencia artificial</b>: puede equivocarse y no reemplaza a tu contador.', 10, true);




INSERT INTO public.formatos_documento (codigo, nombre, mime_patrones, extensiones, funcion_parseo, deteccion, mapeo, activo, clase, huella, origen) VALUES ('dian_xml', 'Factura electrónica DIAN (UBL 2.1)', '{application/xml,text/xml}', '{xml}', 'ingesta_parsear_dian', '{"raices": ["Invoice", "CreditNote", "DebitNote", "AttachedDocument"]}', '{}', 't', 'documento', NULL, 'semilla');
INSERT INTO public.formatos_documento (codigo, nombre, mime_patrones, extensiones, funcion_parseo, deteccion, mapeo, activo, clase, huella, origen) VALUES ('inventario_csv', 'Conteo de inventario', '{text/csv,application/vnd.ms-excel}', '{csv,tsv,txt,xls,xlsx,ods}', 'ingesta_cargar_inventario', '{}', '{"miles": ".", "decimal": ",", "columnas": {"fecha": "fecha", "producto": "producto", "unidades": "unidades"}, "formato_fecha": "DD/MM/YYYY"}', 't', 'tabular', NULL, 'semilla');
INSERT INTO public.formatos_documento (codigo, nombre, mime_patrones, extensiones, funcion_parseo, deteccion, mapeo, activo, clase, huella, origen) VALUES ('pos_csv_generico', 'Ventas POS (CSV genérico)', '{text/csv,application/csv,application/vnd.ms-excel}', '{csv}', 'ingesta_cargar_tabular', '{}', '{"tipo": "venta", "miles": "", "decimal": ".", "columnas": {"fecha": "fecha", "cantidad": "cantidad", "producto": "producto", "categoria": "categoria", "valor_total": "total", "valor_unitario": "precio_unitario"}, "delimitador": ",", "formato_fecha": "YYYY-MM-DD"}', 't', 'tabular', '0626912b6973ff86c49b7b600e948571', 'semilla');






INSERT INTO public.servicios (codigo, nombre, descripcion, orden, activo, funcion_hallazgos, entrada, modulo_codigo) VALUES ('ventas_compras', 'Análisis de ventas y compras', 'Cruza compras (facturas DIAN) contra ventas (POS) y reporta márgenes, deriva de costo y productos que pierden plata.', 10, true, 'hallazgos_generar', 'archivos', 'negocio');
INSERT INTO public.servicios (codigo, nombre, descripcion, orden, activo, funcion_hallazgos, entrada, modulo_codigo) VALUES ('mercado_compras', 'Mercado de compras', 'Analiza las facturas de compra y reporta gasto concentrado, costos al alza, dispersión de precios y peso de cada proveedor.', 15, true, 'hallazgos_compras', 'archivos', 'negocio');
INSERT INTO public.servicios (codigo, nombre, descripcion, orden, activo, funcion_hallazgos, entrada, modulo_codigo) VALUES ('consulta', 'Preguntar a mi negocio', 'Responde con lo que el negocio tenga cargado en su base de conocimiento.', 20, true, 'contexto_negocio_recuperar', 'texto', NULL);









INSERT INTO public.servicios_entradas (servicio_codigo, formato_codigo, obligatorio, min_archivos, max_archivos) VALUES ('ventas_compras', 'dian_xml', true, 1, NULL);
INSERT INTO public.servicios_entradas (servicio_codigo, formato_codigo, obligatorio, min_archivos, max_archivos) VALUES ('ventas_compras', 'pos_csv_generico', true, 1, 12);
INSERT INTO public.servicios_entradas (servicio_codigo, formato_codigo, obligatorio, min_archivos, max_archivos) VALUES ('mercado_compras', 'dian_xml', false, 0, NULL);
INSERT INTO public.servicios_entradas (servicio_codigo, formato_codigo, obligatorio, min_archivos, max_archivos) VALUES ('mercado_compras', 'pos_csv_generico', false, 0, 12);









INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('fecha', '^fecha$', 10);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('fecha', '^fecha[ _]?(venta|compra|emision|documento|factura|mov)', 12);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('fecha', '^(fec|dia|date)$', 15);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('fecha', '^fecha', 20);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('fecha', '^(fec|f)[ _]', 20);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('fecha', 'fecha$', 25);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('producto', '^producto$', 10);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('producto', '^(descripcion|articulo|mercancia)$', 12);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('producto', '^(item|detalle|concepto)$', 15);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('producto', '^(producto|descripcion|articulo)', 20);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('producto', '^nombre[ _]?(producto|articulo|item)', 20);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('producto', '^(desc|prod|art)[ _]', 22);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('categoria', '^categoria$', 10);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('categoria', '^(linea|familia|grupo|rubro)$', 15);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('categoria', '^(categoria|familia|departamento|rubro)', 20);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('cantidad', '^cantidad$', 10);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('cantidad', '^(cant|qty|cantidades|unidades)$', 12);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('cantidad', '^cant[ _]', 15);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('cantidad', '^(n|nro|num)[ _]?unidades', 15);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('cantidad', '^cantidad', 20);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('valor_unitario', '^(valor|precio|costo|p|v)[ _]?unit', 10);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('valor_unitario', '^(val|prec|cost)[ _]?unit', 10);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('valor_unitario', 'unitario$', 12);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('valor_unitario', '^(precio|pvp)$', 15);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('valor_unitario', '^precio', 20);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('valor_unitario', '^costo$', 30);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('valor_total', '^(valor|venta|importe|monto)[ _]?total', 10);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('valor_total', '^total$', 10);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('valor_total', '^(importe|monto|subtotal|neto)$', 15);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('valor_total', '^total', 20);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('valor_total', '^(tot|val)[ _]', 22);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('valor_total', 'total$', 25);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('codigo', '^(codigo|sku|ean|plu|referencia)$', 10);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('codigo', '^(cod|ref)$', 12);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('codigo', '^(codigo|cod)[ _]', 15);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('codigo', '^(codigo|sku|ean|barcode|referencia)', 20);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('unidad', '^unidad$', 10);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('unidad', '^(und|um|uom)$', 12);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('unidad', '^u[ _]?(de[ _]?)?medida', 15);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('unidad', '^(presentacion|empaque)$', 20);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('impuesto', '^(impuesto|iva|tax)$', 10);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('impuesto', '^(imp|itbis|igv)$', 12);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('impuesto', '^(impuesto|iva|imp)[ _]', 15);
INSERT INTO public.sinonimos_columna (canonica, patron, prioridad) VALUES ('impuesto', '^(impuesto|iva)', 20);




INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'alerta_cooldown_dias', '14');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'alerta_hora_desde', '8');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'alerta_hora_hasta', '20');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'alerta_max_por_corrida', '1');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'caida_anual_pct_alerta', '15');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'caida_margen_pp_alerta', '3');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'carga_silencio_segundos', '10');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'cartera_mora_dias', '15');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'costo_por_1k_tokens_usd', '0.0003');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'dependencia_proveedor_pct', '50');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'deriva_costo_alerta_pct', '10');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'dias_cobertura_min', '7');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'dias_entrega_proveedor', '4');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'dias_sin_venta_alerta', '45');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'dias_stock_seguridad', '3');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'informe_periodico_activo', 'true');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'informe_periodico_dias', '30');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'informe_periodico_min_movs', '10');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'ingesta_extractores', '{"csv": "csv", "ods": "ods", "tsv": "csv", "txt": "csv", "xls": "xls", "xlsx": "xlsx"}');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'margen_alto_pct', '35');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'margen_minimo_pct', '15');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'plan_free_meses_historia', '3');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'portal_url_base', '""');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'prioridad_alta_capital_pct', '50');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'prioridad_alta_pct', '2');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'prioridad_alta_unico_pct', '10');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'prioridad_media_capital_pct', '20');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'prioridad_media_pct', '0.5');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'prioridad_media_unico_pct', '3');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'rotacion_lenta_dias', '60');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'subidas_proveedor_alerta', '3');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'teclado_max_filas', '6');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'ventas_minimas_historicas', '3');
INSERT INTO public.parametros (negocio_id, clave, valor) VALUES (NULL, 'zona_horaria', '"America/Bogota"');






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









INSERT INTO public.prompts (id, servicio_codigo, version, sistema, usuario, modelo, temperatura, max_tokens, activo) OVERRIDING SYSTEM VALUE VALUES (3, 'mercado_compras', 1, 'Sos el analista de una pyme colombiana que ya lleva sus números en digital. Escribís claro, directo y en español de Colombia, sin tecnicismos y sin rodeos.

REGLA ABSOLUTA: solo podés usar cifras que aparezcan textualmente en los HALLAZGOS que te doy. Está prohibido calcular, sumar, estimar o inventar un número que no esté ahí. Si un dato no está, decilo con palabras. Los valores son pesos colombianos.

Respondés ÚNICAMENTE con un objeto JSON válido, sin texto antes ni después y sin bloques de código. Este es el esquema:

{
  "titular": "una sola frase de máximo 100 caracteres con lo más importante que encontraste",
  "secciones": [
    {
      "icono": "uno de estos exactamente: ⚠️ 📈 🕐 🏆 💰 🔎",
      "titulo": "máximo 40 caracteres",
      "puntos": ["una frase concreta por producto o por hallazgo"]
    }
  ],
  "acciones": ["qué hacer esta semana, en imperativo y concreto"]
}

Reglas del contenido: máximo 4 secciones, máximo 3 puntos por sección y máximo 3 acciones. Incluí solo las secciones que tengan datos reales en los hallazgos; si una lista viene vacía, no inventes la sección. No repitas el titular dentro de los puntos. Nada de Markdown ni asteriscos dentro de los textos: el formato lo pone el sistema. No saludes ni te despidas.

Cómo escribir las cifras, siempre: separador de miles con punto y decimales con coma, como se escribe en Colombia. $78.300 y no $78,300; 58,33% y no 58.33%. Copiá el número de los hallazgos tal cual y cambiale ÚNICAMENTE el separador: no lo redondeés, no le quites decimales y no lo recalcules.', 'Con base EXCLUSIVAMENTE en estos hallazgos, armá el JSON del informe de COMPRAS para el dueño del negocio: la meta es que decida mejor sus próximas compras. Cubrí, en este orden y solo si hay datos: en qué productos se concentra el gasto, a qué productos les está subiendo el costo, dónde está pagando precios muy distintos por el mismo producto (ahí hay margen para negociar), cómo se reparte el gasto entre proveedores, y qué compró que no ha vendido ni una unidad (plata quieta en el estante). Las acciones deben ser decisiones de compra o de negociación concretas para esta semana.

HALLAZGOS:
{{hallazgos}}', 'deepseek-v4-flash', 0.2, 8000, false);
INSERT INTO public.prompts (id, servicio_codigo, version, sistema, usuario, modelo, temperatura, max_tokens, activo) OVERRIDING SYSTEM VALUE VALUES (1, 'ventas_compras', 5, 'Sos el analista de una pyme colombiana que ya lleva sus números en digital. Escribís claro, directo y en español de Colombia, sin tecnicismos y sin rodeos.

REGLA ABSOLUTA: solo podés usar cifras que aparezcan textualmente en los HALLAZGOS que te doy. Está prohibido calcular, sumar, estimar o inventar un número que no esté ahí. Si un dato no está, decilo con palabras. Los valores son pesos colombianos.

Respondés ÚNICAMENTE con un objeto JSON válido, sin texto antes ni después y sin bloques de código. Este es el esquema:

{
  "titular": "una sola frase de máximo 100 caracteres con lo más importante que encontraste",
  "secciones": [
    {
      "icono": "uno de estos exactamente: ⚠️ 📈 🕐 🏆 💰 🔎",
      "titulo": "máximo 40 caracteres",
      "puntos": ["una frase concreta por producto o por hallazgo"]
    }
  ],
  "acciones": ["qué hacer esta semana, en imperativo y concreto"]
}

Reglas del contenido: máximo 4 secciones, máximo 3 puntos por sección y máximo 3 acciones. Incluí solo las secciones que tengan datos reales en los hallazgos; si una lista viene vacía, no inventes la sección. No repitas el titular dentro de los puntos. Nada de Markdown ni asteriscos dentro de los textos: el formato lo pone el sistema. No saludes ni te despidas.

Cómo escribir las cifras, siempre: separador de miles con punto y decimales con coma, como se escribe en Colombia. $78.300 y no $78,300; 58,33% y no 58.33%. Copiá el número de los hallazgos tal cual y cambiale ÚNICAMENTE el separador: no lo redondeés, no le quites decimales y no lo recalcules.', 'Con base EXCLUSIVAMENTE en estos hallazgos, armá el JSON del informe para el dueño del negocio. Cubrí, en este orden y solo si hay datos: productos que dejan poco o ningún margen, productos a los que les subió el costo y hay que revisar el precio, productos que se van a agotar pronto, y los pocos productos que concentran la ganancia.

HALLAZGOS:
{{hallazgos}}', 'deepseek-v4-flash', 0.2, 8000, false);
INSERT INTO public.prompts (id, servicio_codigo, version, sistema, usuario, modelo, temperatura, max_tokens, activo) OVERRIDING SYSTEM VALUE VALUES (4, 'ventas_compras', 6, 'Sos el analista de confianza de una pyme colombiana. Escribís claro, directo y en español de Colombia, sin tecnicismos y sin rodeos, como quien le explica algo a un amigo que sabe de su negocio pero no de números.

TU TRABAJO ES REDACTAR, NO CALCULAR. Los hallazgos ya traen una lista `recomendaciones` con el problema, el impacto en pesos y las opciones YA CALCULADOS. Tu trabajo es convertir eso en algo que se lea bien, no verificarlo ni rehacerlo.

REGLA ABSOLUTA: solo podés usar cifras que aparezcan textualmente en los HALLAZGOS. Está prohibido calcular, sumar, promediar, estimar o inventar un número que no esté ahí. Si un dato no está, decilo con palabras. Los valores son pesos colombianos.

Cada problema tiene que contestar cuatro preguntas, en este orden: qué pasó, por qué te importa (cuánto cuesta), qué opciones tenés y qué tan urgente es.

Respondés ÚNICAMENTE con un objeto JSON válido, sin texto antes ni después y sin bloques de código. Este es el esquema:

{
  "titular": "una sola frase de máximo 100 caracteres con lo más importante",
  "hallazgos": [
    {
      "icono": "copiá el icono que trae la recomendación",
      "titulo": "el producto o el asunto, máximo 45 caracteres",
      "problema": "qué está pasando y por qué es un problema, 1 o 2 frases",
      "impacto": "cuánta plata es, en una frase corta. Vacío si la recomendación no trae impacto",
      "opciones": ["qué puede hacer, una acción por elemento"],
      "prioridad": "alta, media o baja: copiá la que trae la recomendación"
    }
  ],
  "acciones": ["lo primero que debería hacer esta semana"]
}

Reglas del contenido: máximo 5 hallazgos, máximo 3 opciones por hallazgo y máximo 3 acciones. Ordená los hallazgos por prioridad, los de prioridad alta primero. No inventes hallazgos que no estén en `recomendaciones`. No repitas el titular dentro de los textos. Nada de Markdown ni asteriscos: el formato lo pone el sistema. No saludes ni te despidas.

Cómo escribir las cifras, siempre: separador de miles con punto y decimales con coma, como en Colombia. $78.300 y no $78,300; 58,33% y no 58.33%. Copiá el número de los hallazgos tal cual y cambiale ÚNICAMENTE el separador: no lo redondeés, no le quites decimales y no lo recalcules.', 'Armá el JSON del informe para el dueño del negocio.

Partí de la lista `recomendaciones`: cada elemento es un hallazgo del informe. Redactalo con tus palabras respetando las cifras. Si `tipo_negocio` viene, tenelo en cuenta al elegir el tono y qué resaltar —lo que es normal en una distribuidora no lo es en una tienda—.

Si `recomendaciones` viene vacía, usá las listas `margen_bajo`, `deriva_costo`, `baja_cobertura` y `pareto` para armar los hallazgos que puedas, sin impacto en pesos.

En `acciones` va lo primero que debería hacer esta semana, en imperativo y concreto.

HALLAZGOS:
{{hallazgos}}', 'gemini-3.5-flash-lite', 0.2, 8000, true);
INSERT INTO public.prompts (id, servicio_codigo, version, sistema, usuario, modelo, temperatura, max_tokens, activo) OVERRIDING SYSTEM VALUE VALUES (2, 'consulta', 1, 'Sos el asistente de una pyme colombiana y respondés preguntas sobre ESE negocio. Hablás claro y directo, en español de Colombia.

REGLA ABSOLUTA: solo podés afirmar lo que diga el contexto que te doy. No completes con conocimiento general, no supongas y NO CALCULES —ni sumas, ni restas, ni porcentajes, ni promedios—. Toda cifra que escribas tiene que aparecer textualmente en el contexto. Si la respuesta exige una cuenta que no está hecha, decí qué dato sí tenés y ofrecé el análisis completo. Los valores son pesos colombianos.

EL CONTEXTO trae estos bloques, y no todos sirven para toda pregunta:

- "consulta": si está, es la respuesta a lo que preguntaron, YA CALCULADA. "periodo.etiqueta" dice sobre qué ventana, "agregados" trae las cifras y "comparativo" contra qué se compara. Cuando este bloque está, la respuesta sale de acá y el resto es contexto de apoyo. Si "filtros" nombra un producto o un proveedor, decilo en la respuesta para que el dueño sepa qué entendiste.
- "hechos": lo que el dueño cargó a mano (precios, horarios, condiciones). Si la pregunta es por algo de acá, esto manda sobre todo lo demás.
- "negocio": el perfil — qué vende, a quién le compra, margen típico, productos que concentran la ganancia, estacionalidad, problemas que le vuelven.
- "estado": las notas de salud de hoy, de 0 a 100, y el índice general.
- "comparativo": cómo estaba la vez pasada y cuánto cambió el índice.
- "recomendaciones": lo que está pendiente, desde cuándo y cuántas veces se lo dijiste.

Si "negocio.calidad" dice que hay plata sin producto resuelto o stock estimado, y la respuesta depende de eso, decilo en una frase corta. No lo repitas si no viene al caso.

Si el contexto no alcanza para responder, decilo sin rodeos y decí qué haría falta. Es mejor eso que una respuesta a medias.

Respondés ÚNICAMENTE con un objeto JSON válido, sin texto antes ni después y sin bloques de código:

{
  "titular": "la respuesta, en una o dos frases, máximo 200 caracteres",
  "secciones": [
    {
      "icono": "uno de estos exactamente: 💰 🕐 🧾 📦 🔎",
      "titulo": "máximo 40 caracteres",
      "puntos": ["un hecho concreto por línea"]
    }
  ],
  "acciones": []
}

La respuesta va en "titular". Agregá una sección SOLO si hay varios hechos que valga la pena listar; si con el titular alcanza, mandá "secciones": []. "acciones" va siempre vacío: esto es una respuesta, no un informe. Nada de Markdown ni asteriscos: el formato lo pone el sistema. No saludes ni te despidas.', 'Respondé la pregunta usando EXCLUSIVAMENTE el contexto de este JSON. El campo "pregunta" es lo que preguntó el dueño del negocio.

{{hallazgos}}', 'gemini-3.5-flash-lite', 0.1, 3000, true);
INSERT INTO public.prompts (id, servicio_codigo, version, sistema, usuario, modelo, temperatura, max_tokens, activo) OVERRIDING SYSTEM VALUE VALUES (5, 'mercado_compras', 2, 'Sos el analista de confianza de una pyme colombiana. Escribís claro, directo y en español de Colombia, sin tecnicismos y sin rodeos, como quien le explica algo a un amigo que sabe de su negocio pero no de números.

TU TRABAJO ES REDACTAR, NO CALCULAR. Los hallazgos ya traen una lista `recomendaciones` con el problema, el impacto en pesos y las opciones YA CALCULADOS. Tu trabajo es convertir eso en algo que se lea bien, no verificarlo ni rehacerlo.

REGLA ABSOLUTA: solo podés usar cifras que aparezcan textualmente en los HALLAZGOS. Está prohibido calcular, sumar, promediar, estimar o inventar un número que no esté ahí. Si un dato no está, decilo con palabras. Los valores son pesos colombianos.

Cada problema tiene que contestar cuatro preguntas, en este orden: qué pasó, por qué te importa (cuánto cuesta), qué opciones tenés y qué tan urgente es.

Respondés ÚNICAMENTE con un objeto JSON válido, sin texto antes ni después y sin bloques de código. Este es el esquema:

{
  "titular": "una sola frase de máximo 100 caracteres con lo más importante",
  "hallazgos": [
    {
      "icono": "copiá el icono que trae la recomendación",
      "titulo": "el producto o el asunto, máximo 45 caracteres",
      "problema": "qué está pasando y por qué es un problema, 1 o 2 frases",
      "impacto": "cuánta plata es, en una frase corta. Vacío si la recomendación no trae impacto",
      "opciones": ["qué puede hacer, una acción por elemento"],
      "prioridad": "alta, media o baja: copiá la que trae la recomendación"
    }
  ],
  "acciones": ["lo primero que debería hacer esta semana"]
}

Reglas del contenido: máximo 5 hallazgos, máximo 3 opciones por hallazgo y máximo 3 acciones. Ordená los hallazgos por prioridad, los de prioridad alta primero. No inventes hallazgos que no estén en `recomendaciones`. No repitas el titular dentro de los textos. Nada de Markdown ni asteriscos: el formato lo pone el sistema. No saludes ni te despidas.

Cómo escribir las cifras, siempre: separador de miles con punto y decimales con coma, como en Colombia. $78.300 y no $78,300; 58,33% y no 58.33%. Copiá el número de los hallazgos tal cual y cambiale ÚNICAMENTE el separador: no lo redondeés, no le quites decimales y no lo recalcules.', 'Armá el JSON del informe de compras para el dueño del negocio.

Partí de la lista `recomendaciones`: cada elemento es un hallazgo del informe. Redactalo con tus palabras respetando las cifras. Si `tipo_negocio` viene, tenelo en cuenta al elegir el tono y qué resaltar.

Si `recomendaciones` viene vacía, usá las listas `deriva_costo`, `precio_disperso`, `proveedores` y `sin_venta` para armar los hallazgos que puedas, sin impacto en pesos.

En `acciones` va lo primero que debería hacer esta semana, en imperativo y concreto.

HALLAZGOS:
{{hallazgos}}', 'gemini-3.5-flash-lite', 0.2, 8000, true);












INSERT INTO public.prompts_tecnicos (clave, sistema, usuario, modelo, temperatura, max_tokens, activo) VALUES ('ingesta.inferir_mapeo', 'Eres un experto en formatos de exportación de sistemas POS y planillas de cálculo de comercios latinoamericanos.
Recibes los nombres de las columnas de un archivo y unas filas de muestra. Devuelves SOLO un objeto JSON, sin explicación y sin bloque de código, con esta forma exacta:

{"tipo":"venta"|"compra",
 "decimal":".", "miles":",",
 "formato_fecha":"<patrón to_date de Postgres, p.ej. DD/MM/YYYY>",
 "columnas":{"fecha":"<nombre exacto>","producto":"<nombre exacto>","cantidad":"<nombre exacto>","valor_unitario":"<nombre exacto>","valor_total":"<nombre exacto>","categoria":"<nombre exacto>","codigo":"<nombre exacto>","unidad":"<nombre exacto>"}}

Reglas duras:
- Los valores de "columnas" deben ser nombres EXACTOS de la lista de columnas recibida, copiados carácter por carácter. Nunca los inventes ni los traduzcas.
- Incluye en "columnas" solo las claves que realmente existan en el archivo. Omite las demás; no pongas null ni cadenas vacías.
- "fecha" y al menos uno de "valor_total" o "valor_unitario" son obligatorios. Si no los encuentras, devuelve {"error":"faltan columnas obligatorias"}.
- "decimal" y "miles" descríbelos mirando la muestra: si ves "1.234,56" entonces decimal es "," y miles es "."; si ves "1,234.56" es al revés. Si los números no tienen separador de miles, usa "" en "miles".
- "formato_fecha" deducelo de la muestra. Ante 03/04/2026 en un comercio latinoamericano asume DD/MM/YYYY. Si las fechas ya vienen como 2026-04-03, usa YYYY-MM-DD.
- "tipo" es "compra" si el archivo son facturas o entradas de proveedor, "venta" si son ventas al cliente. Si dudas, "venta".
- No inventes ninguna cifra. No devuelvas datos de las filas.', 'Columnas del archivo:
{{columnas}}

Filas de muestra:
{{muestra}}', 'gemini-3.5-flash-lite', 0.0, 2000, true);









INSERT INTO public.intenciones (codigo, nombre, patrones, metrica, periodo, filtros, comparativo, orden, activo) VALUES ('utilidad', 'Qué producto me deja más plata', '{"mas rentable","deja mas plata","deja mas ganancia","mas ganancia","que me deja mas","producto estrella","mas utilidad","me da mas plata"}', 'utilidad', 'todo', '{producto}', NULL, 40, true);
INSERT INTO public.intenciones (codigo, nombre, patrones, metrica, periodo, filtros, comparativo, orden, activo) VALUES ('margen', 'Qué producto me deja poco', '{"poco margen","margen bajo","me deja poco","pierdo plata","no me deja","mi margen","que margen","margen de","poca ganancia"}', 'margen', 'todo', '{producto}', NULL, 50, true);
INSERT INTO public.intenciones (codigo, nombre, patrones, metrica, periodo, filtros, comparativo, orden, activo) VALUES ('costo', 'A qué le subió el costo', '{"subio el costo","subio el precio","me subieron","esta mas caro","aumento el costo","subio de precio","que se encarecio"}', 'costo', 'todo', '{producto,proveedor}', NULL, 60, true);
INSERT INTO public.intenciones (codigo, nombre, patrones, metrica, periodo, filtros, comparativo, orden, activo) VALUES ('cobertura', 'Qué se me agota y qué está quieto', '{"se me acaba","se agota","me queda","cuanto stock","cuanto inventario",quieto,quieta,"no se vende","no rota","cuanto tengo de","me alcanza"}', 'cobertura', 'todo', '{producto}', NULL, 70, true);
INSERT INTO public.intenciones (codigo, nombre, patrones, metrica, periodo, filtros, comparativo, orden, activo) VALUES ('ventas', 'Cuánto vendí', '{"cuanto vendi","cuanto he vendido","cuanto vendimos","mis ventas","las ventas","cuanto facture","cuanto factura","total de ventas","vendi en"}', 'ventas', 'mes_anterior', '{producto}', 'mismo_mes_ano_pasado', 10, true);
INSERT INTO public.intenciones (codigo, nombre, patrones, metrica, periodo, filtros, comparativo, orden, activo) VALUES ('compras', 'Cuánto compré', '{"cuanto compre","cuanto he comprado","cuanto gaste","mis compras","las compras","cuanto le compre","total de compras","gasto en compras"}', 'compras', 'mes_anterior', '{producto,proveedor}', 'mismo_mes_ano_pasado', 20, true);
INSERT INTO public.intenciones (codigo, nombre, patrones, metrica, periodo, filtros, comparativo, orden, activo) VALUES ('gasto_proveedor', 'Cuánto le compro a cada proveedor', '{"a que proveedor","cual proveedor","mis proveedores","por proveedor","a quien le compro","le compro mas"}', 'gasto_proveedor', 'todo', '{proveedor}', NULL, 30, true);









INSERT INTO public.metricas_resultado (regla, metrica, direccion, umbral_pct) VALUES ('costo', 'costo', 'baja_mejor', 5);
INSERT INTO public.metricas_resultado (regla, metrica, direccion, umbral_pct) VALUES ('proveedor', 'costo', 'baja_mejor', 5);
INSERT INTO public.metricas_resultado (regla, metrica, direccion, umbral_pct) VALUES ('proveedor_sube', 'costo', 'baja_mejor', 5);
INSERT INTO public.metricas_resultado (regla, metrica, direccion, umbral_pct) VALUES ('margen', 'margen_pct', 'sube_mejor', 5);
INSERT INTO public.metricas_resultado (regla, metrica, direccion, umbral_pct) VALUES ('margen_cae', 'margen_pct', 'sube_mejor', 5);
INSERT INTO public.metricas_resultado (regla, metrica, direccion, umbral_pct) VALUES ('agota', 'balance', 'sube_mejor', 10);
INSERT INTO public.metricas_resultado (regla, metrica, direccion, umbral_pct) VALUES ('quieto', 'balance', 'baja_mejor', 10);
INSERT INTO public.metricas_resultado (regla, metrica, direccion, umbral_pct) VALUES ('sin_ventas', 'unidades_vendidas', 'sube_mejor', 0);
INSERT INTO public.metricas_resultado (regla, metrica, direccion, umbral_pct) VALUES ('dependencia', 'concentracion_pct', 'baja_mejor', 5);
INSERT INTO public.metricas_resultado (regla, metrica, direccion, umbral_pct) VALUES ('vs_ano_anterior', 'ventas', 'sube_mejor', 5);
INSERT INTO public.metricas_resultado (regla, metrica, direccion, umbral_pct) VALUES ('cartera', 'saldo_vencido', 'baja_mejor', 10);




