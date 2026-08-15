-- 011_modelo_deepseek_v4.sql — DeepSeek renombró sus modelos.
-- 'deepseek-chat' ya no existe; los válidos son deepseek-v4-flash (barato,
-- razona) y deepseek-v4-pro (mejor redacción, más caro). Se usa flash por
-- defecto; cambiar a pro es un UPDATE, no tocar n8n.
UPDATE prompts SET modelo = 'deepseek-v4-flash'
WHERE modelo = 'deepseek-chat';

-- Y que el default de la columna acompañe.
ALTER TABLE prompts ALTER COLUMN modelo SET DEFAULT 'deepseek-v4-flash';
