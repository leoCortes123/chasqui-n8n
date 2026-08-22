-- 020_informe_en_chat.sql — el informe se entrega como texto en el chat, no como PDF.
--
-- Y de paso la causa real de que el informe saliera "cortado", que NO era el PDF:
--
--   ejecucion 14: tokens_salida = 1200  con  prompts.max_tokens = 1200
--
-- El modelo se quedó sin cupo a mitad de frase y el PDF renderizó fielmente un
-- texto truncado. Agravante: deepseek-v4-flash razona, y los reasoning_tokens
-- cuentan dentro de completion_tokens, así que de esos 1200 una parte grande no
-- era informe (la ejecución 14 produjo 937 caracteres con 1200 tokens). El cupo
-- sube a 4000 y wf_ejecutar además detecta finish_reason='length' para no
-- entregar nunca más media frase como si estuviera completa.
UPDATE prompts SET max_tokens = 4000, version = version + 1
WHERE servicio_codigo = 'ventas_compras' AND activo;

-- El informe viaja en {{informe}} dentro de la primera plantilla, así el
-- encabezado sigue siendo editable desde la base y no queda incrustado en un
-- nodo de n8n.
UPDATE plantillas SET cuerpo =
'📊 Tu análisis de {{servicio}} está listo.

{{informe}}',
  variables = '["servicio","informe"]'::jsonb,
  version = version + 1
WHERE clave = 'ejecucion.entregada';

-- Telegram corta los mensajes en 4096 caracteres. Un informe largo se parte y
-- las partes siguientes salen sin encabezado, con esta plantilla.
INSERT INTO plantillas (clave, cuerpo, formato, variables) VALUES
('ejecucion.informe_parte', '{{texto}}', 'plain', '["texto"]'::jsonb)
ON CONFLICT (clave) DO UPDATE
  SET cuerpo = EXCLUDED.cuerpo, formato = EXCLUDED.formato,
      variables = EXCLUDED.variables, activo = true;
