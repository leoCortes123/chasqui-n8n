




INSERT INTO public.servicios (codigo, nombre, descripcion, orden, activo, funcion_hallazgos, entrada, modulo_codigo) VALUES ('ventas_compras', 'Análisis de ventas y compras', 'Cruza compras (facturas DIAN) contra ventas (POS) y reporta márgenes, deriva de costo y productos que pierden plata.', 10, true, 'hallazgos_generar', 'archivos', 'negocio');
INSERT INTO public.servicios (codigo, nombre, descripcion, orden, activo, funcion_hallazgos, entrada, modulo_codigo) VALUES ('mercado_compras', 'Mercado de compras', 'Analiza las facturas de compra y reporta gasto concentrado, costos al alza, dispersión de precios y peso de cada proveedor.', 15, true, 'hallazgos_compras', 'archivos', 'negocio');
INSERT INTO public.servicios (codigo, nombre, descripcion, orden, activo, funcion_hallazgos, entrada, modulo_codigo) VALUES ('consulta', 'Preguntar a mi negocio', 'Responde con lo que el negocio tenga cargado en su base de conocimiento.', 20, true, 'contexto_negocio_recuperar', 'texto', NULL);




