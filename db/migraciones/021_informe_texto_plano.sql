-- 021_informe_texto_plano.sql — el informe se lee en el chat, así que se escribe
-- en texto plano.
--
-- Los nodos de Telegram van sin parse_mode (additionalFields solo lleva
-- appendAttribution), así que Telegram muestra el texto crudo. Mientras el
-- informe iba en PDF daba igual; ahora que se lee en el chat, el Markdown del
-- modelo aparece como basura literal:
--
--   1. **Productos con margen bajo:** El *ACEITE PREMIER 1L* tiene...
--
-- No se activa parse_mode a propósito: el Markdown legacy de Telegram revienta
-- el envío entero ("can't parse entities") ante un asterisco o guion bajo
-- desbalanceado, y el texto lo escribe un modelo, no nosotros. Un informe que no
-- llega es peor que uno sin negritas. Así que se le pide texto plano al modelo,
-- y wf_ejecutar limpia igual lo que se le escape.
UPDATE prompts SET
    sistema = sistema || ' Escribe en TEXTO PLANO: nada de Markdown, ni asteriscos, ni guiones bajos, ni almohadillas, ni bloques de código. Se lee directo en un chat de Telegram. Para separar temas usa saltos de línea, y para enumerar usa un guion (-) al principio de la línea.',
    version = version + 1
WHERE servicio_codigo = 'ventas_compras' AND activo;
