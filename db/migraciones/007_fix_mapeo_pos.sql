-- 007_fix_mapeo_pos.sql — corrige el mapeo del POS genérico.
-- Las claves de 'columnas' deben ser los campos canónicos que lee
-- ingesta_cargar_tabular (valor_unitario, valor_total), no los del proveedor.
UPDATE formatos_documento
SET mapeo = '{"columnas": {"fecha":"fecha","producto":"producto","categoria":"categoria",
                           "cantidad":"cantidad","valor_unitario":"precio_unitario",
                           "valor_total":"total"},
              "tipo": "venta", "separador": ",", "decimal": "."}'::jsonb
WHERE codigo = 'pos_csv_generico';
