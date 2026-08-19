




INSERT INTO public.intenciones (codigo, nombre, patrones, metrica, periodo, filtros, comparativo, orden, activo) VALUES ('utilidad', 'Qué producto me deja más plata', '{"mas rentable","deja mas plata","deja mas ganancia","mas ganancia","que me deja mas","producto estrella","mas utilidad","me da mas plata"}', 'utilidad', 'todo', '{producto}', NULL, 40, true);
INSERT INTO public.intenciones (codigo, nombre, patrones, metrica, periodo, filtros, comparativo, orden, activo) VALUES ('margen', 'Qué producto me deja poco', '{"poco margen","margen bajo","me deja poco","pierdo plata","no me deja","mi margen","que margen","margen de","poca ganancia"}', 'margen', 'todo', '{producto}', NULL, 50, true);
INSERT INTO public.intenciones (codigo, nombre, patrones, metrica, periodo, filtros, comparativo, orden, activo) VALUES ('costo', 'A qué le subió el costo', '{"subio el costo","subio el precio","me subieron","esta mas caro","aumento el costo","subio de precio","que se encarecio"}', 'costo', 'todo', '{producto,proveedor}', NULL, 60, true);
INSERT INTO public.intenciones (codigo, nombre, patrones, metrica, periodo, filtros, comparativo, orden, activo) VALUES ('cobertura', 'Qué se me agota y qué está quieto', '{"se me acaba","se agota","me queda","cuanto stock","cuanto inventario",quieto,quieta,"no se vende","no rota","cuanto tengo de","me alcanza"}', 'cobertura', 'todo', '{producto}', NULL, 70, true);
INSERT INTO public.intenciones (codigo, nombre, patrones, metrica, periodo, filtros, comparativo, orden, activo) VALUES ('ventas', 'Cuánto vendí', '{"cuanto vendi","cuanto he vendido","cuanto vendimos","mis ventas","las ventas","cuanto facture","cuanto factura","total de ventas","vendi en"}', 'ventas', 'mes_anterior', '{producto}', 'mismo_mes_ano_pasado', 10, true);
INSERT INTO public.intenciones (codigo, nombre, patrones, metrica, periodo, filtros, comparativo, orden, activo) VALUES ('compras', 'Cuánto compré', '{"cuanto compre","cuanto he comprado","cuanto gaste","mis compras","las compras","cuanto le compre","total de compras","gasto en compras"}', 'compras', 'mes_anterior', '{producto,proveedor}', 'mismo_mes_ano_pasado', 20, true);
INSERT INTO public.intenciones (codigo, nombre, patrones, metrica, periodo, filtros, comparativo, orden, activo) VALUES ('gasto_proveedor', 'Cuánto le compro a cada proveedor', '{"a que proveedor","cual proveedor","mis proveedores","por proveedor","a quien le compro","le compro mas"}', 'gasto_proveedor', 'todo', '{proveedor}', NULL, 30, true);




