




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




