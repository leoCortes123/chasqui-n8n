




INSERT INTO public.formatos_documento (codigo, nombre, mime_patrones, extensiones, funcion_parseo, deteccion, mapeo, activo, clase, huella, origen) VALUES ('dian_xml', 'Factura electrónica DIAN (UBL 2.1)', '{application/xml,text/xml}', '{xml}', 'ingesta_parsear_dian', '{"raices": ["Invoice", "CreditNote", "DebitNote", "AttachedDocument"]}', '{}', true, 'documento', NULL, 'semilla');
INSERT INTO public.formatos_documento (codigo, nombre, mime_patrones, extensiones, funcion_parseo, deteccion, mapeo, activo, clase, huella, origen) VALUES ('inventario_csv', 'Conteo de inventario', '{text/csv,application/vnd.ms-excel}', '{csv,tsv,txt,xls,xlsx,ods}', 'ingesta_cargar_inventario', '{}', '{"miles": ".", "decimal": ",", "columnas": {"fecha": "fecha", "producto": "producto", "unidades": "unidades"}, "formato_fecha": "DD/MM/YYYY"}', true, 'tabular', NULL, 'semilla');
INSERT INTO public.formatos_documento (codigo, nombre, mime_patrones, extensiones, funcion_parseo, deteccion, mapeo, activo, clase, huella, origen) VALUES ('pos_csv_generico', 'Ventas POS (CSV genérico)', '{text/csv,application/csv,application/vnd.ms-excel}', '{csv}', 'ingesta_cargar_tabular', '{}', '{"tipo": "venta", "miles": "", "decimal": ".", "columnas": {"fecha": "fecha", "cantidad": "cantidad", "producto": "producto", "categoria": "categoria", "valor_total": "total", "valor_unitario": "precio_unitario"}, "delimitador": ",", "formato_fecha": "YYYY-MM-DD"}', true, 'tabular', '0626912b6973ff86c49b7b600e948571', 'semilla');
INSERT INTO public.formatos_documento (codigo, nombre, mime_patrones, extensiones, funcion_parseo, deteccion, mapeo, activo, clase, huella, origen) VALUES ('tabular_20a6271e84', 'Tabla agregada (csv)', '{}', '{csv}', 'ingesta_cargar_tabular', '{}', '{"tipo": "venta", "miles": "", "decimal": ".", "agregado": true, "columnas": {"fecha": "Fecha", "valor_total": "Total_Ventas"}, "formato_fecha": "YYYY-MM-DD"}', true, 'tabular', '20a6271e84305d6b40d9e7c176282f95', 'inferido');
INSERT INTO public.formatos_documento (codigo, nombre, mime_patrones, extensiones, funcion_parseo, deteccion, mapeo, activo, clase, huella, origen) VALUES ('tabular_29ec2affe3', 'Tabla reconocida (csv)', '{}', '{csv}', 'ingesta_cargar_tabular', '{}', '{"tipo": "venta", "miles": "", "decimal": ".", "agregado": false, "columnas": {"fecha": "Fecha", "codigo": "Codigo_Barras", "unidad": "Unidad", "cantidad": "Cantidad", "impuesto": "IVA_Porcentaje", "producto": "Producto", "categoria": "Categoria", "valor_total": "Total_Linea", "valor_unitario": "Valor_Unitario"}, "formato_fecha": "YYYY-MM-DD"}', true, 'tabular', '29ec2affe36950e61e2525e50ce6e38f', 'inferido');




