-- 049_boton_analizar_en_carga.sql — el botón de analizar vive en el mensaje
-- que pide los archivos.
--
-- Desde la 042 un archivo cargado no contesta nada (para no ametrallar al
-- usuario con un mensaje por archivo), así que el único camino al análisis era
-- esperar la pregunta "¿son todos?" que dispara wf_ingesta unos segundos
-- después. Si esa pregunta se pierde en el scroll —o el usuario sigue
-- mandando archivos y nunca la ve— no queda nada visible para arrancar.
--
-- El mensaje de "mandame los archivos" sí queda fijo arriba de la carga, así
-- que ese es el lugar natural del botón: se mandan todos los archivos y se
-- vuelve a ese mensaje a tocar Analizar. El texto lo dice explícitamente.
--
-- No hace falta tocar el router: /listo ya es el comando que arranca la
-- ejecución dentro del estado 'recibiendo' (y valida que haya al menos un
-- documento parseado, contestando 'sistema.sin_documentos' si el botón se toca
-- antes de tiempo). Tampoco hace falta tocar router_arranque_servicio:
-- resolver_plantilla usa el teclado de la fila cuando la respuesta no trae uno
-- propio (023).

UPDATE plantillas SET cuerpo =
'Listo: <b>{{servicio}}</b>.

Mandame los archivos de <b>facturación</b> de tu negocio: las <b>ventas</b> y las <b>compras</b>. De dónde salgan no me importa —lo que exporte tu sistema, lo que te pase el contador, un Excel que llevés a mano— y tampoco cómo se llamen las columnas: yo los leo.

📎 Me sirven archivos {{formatos}}.

📅 <b>Cuánta historia mandarme:</b> con <b>3 meses</b> ya sale un análisis serio. Entre más me mandes, mejor: las tendencias de costo y lo que rota lento no se ven en dos semanas.

Empezá a mandarlos de a uno. Si algo no lo puedo leer te aviso ahí mismo.

✅ <b>Cuando termines de mandarlos todos, volvé a este mensaje y tocá 📊 Analizar.</b>',
  variables = '["servicio","formatos"]'::jsonb,
  teclado = '[[{"texto":"📊 Analizar","dato":"/listo"}],
              [{"texto":"✖️ Cancelar","dato":"/cancelar"}]]'::jsonb,
  version = version + 1
WHERE clave = 'sistema.pedir_archivos';

NOTIFY pgrst, 'reload schema';
