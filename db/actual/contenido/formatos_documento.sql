




INSERT INTO public.formatos_documento (codigo, nombre, mime_patrones, extensiones, funcion_parseo, deteccion, mapeo, activo, clase, huella, origen) VALUES ('dian_xml', 'Factura electrónica DIAN (UBL 2.1)', '{application/xml,text/xml}', '{xml}', 'ingesta_parsear_dian', '{"raices": ["Invoice", "CreditNote", "DebitNote", "AttachedDocument"]}', '{}', true, 'documento', NULL, 'semilla');
INSERT INTO public.formatos_documento (codigo, nombre, mime_patrones, extensiones, funcion_parseo, deteccion, mapeo, activo, clase, huella, origen) VALUES ('inventario_csv', 'Conteo de inventario', '{text/csv,application/vnd.ms-excel}', '{csv,tsv,txt,xls,xlsx,ods}', 'ingesta_cargar_inventario', '{}', '{"miles": ".", "decimal": ",", "columnas": {"fecha": "fecha", "producto": "producto", "unidades": "unidades"}, "formato_fecha": "DD/MM/YYYY"}', true, 'tabular', NULL, 'semilla');
INSERT INTO public.formatos_documento (codigo, nombre, mime_patrones, extensiones, funcion_parseo, deteccion, mapeo, activo, clase, huella, origen) VALUES ('pos_csv_generico', 'Ventas POS (CSV genérico)', '{text/csv,application/csv,application/vnd.ms-excel}', '{csv}', 'ingesta_cargar_tabular', '{}', '{"tipo": "venta", "miles": "", "decimal": ".", "columnas": {"fecha": "fecha", "cantidad": "cantidad", "producto": "producto", "categoria": "categoria", "valor_total": "total", "valor_unitario": "precio_unitario"}, "delimitador": ",", "formato_fecha": "YYYY-MM-DD"}', true, 'tabular', '0626912b6973ff86c49b7b600e948571', 'semilla');




