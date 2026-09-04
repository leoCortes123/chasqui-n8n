-- quipu_completar.sql — lo que falta cargar en Quipu para que la metodología
-- de PROCESO-002 opere completa. Se aplica sobre la base de Quipu, NO sobre la
-- de Chasqui:
--
--   docker exec -i -e PGPASSWORD=quipu quipu-ent-postgres \
--     psql -U quipu -d quipu -f - < bin/quipu_completar.sql
--
-- Es idempotente. Verificado contra el estado del 2026-08-28 (proyecto chasqui,
-- id 1). Lo que arregla, medido ese día:
--
--   member_role  → nadie tenía rol `negocio` ni `analista`
--   business_rule → 43 rules para 63 invariantes; PRODUCTO-001 sin cargar
--
-- Lo que NO arregla, porque es desarrollo de Quipu y no carga de datos
-- (PROCESO-002 §Consecuencias, Q-1..Q-4): block_rule es tabla muerta,
-- claim_block no envía reglas, business_rule no tiene ciclo de vida, y
-- cambio_ambito() no alcanza bloques de features heredados.

BEGIN;

-- ── 1 · Roles ────────────────────────────────────────────────────────────────
-- `politica_autorizacion` exige firma `autorizo` de rol `negocio` para todo
-- cambio normal de riesgo bajo o medio. Nadie tenía ese rol, así que ningún
-- cambio de riesgo no-alto podía autorizarse: la cadena de gobierno estaba
-- cerrada por configuración, no por diseño.
--
-- `crear_cambio` exige además un analista distinto del solicitante. leonardo
-- (member 3, humano) queda como solicitante y firmante; su agente claude-code
-- (member 4) como analista. Firmar sigue siendo humano: `fn_firmante_humano`
-- rechaza la firma de un agente pase lo que pase.
INSERT INTO member_role (member_id, role_code, assigned_by) VALUES
    (3, 'negocio',  3),   -- leonardo: puede autorizar y aceptar un cambio
    (3, 'analista', 3),   -- leonardo: puede triar necesidades y redactar requisitos
    (4, 'analista', 3)    -- leonardo (claude-code): analista, nunca firmante
ON CONFLICT (member_id, role_code) DO NOTHING;

-- ── 2 · PRODUCTO-001 ─────────────────────────────────────────────────────────
-- La única decisión vigente de Chasqui sin ninguna regla espejo en Quipu.
-- Va al feature `core`, que es donde viven las decisiones transversales.
INSERT INTO business_rule (feature_id, code, rule_type, description)
SELECT f.id, v.code, v.rule_type, v.description
FROM feature f
CROSS JOIN (VALUES
    ('PRODUCTO-001-1', 'constraint',
     'No se disena para un negocio que no tiene registros digitales de ventas o compras.'),
    ('PRODUCTO-001-2', 'constraint',
     'Una funcionalidad que exija digitar movimientos a mano como flujo principal esta fuera.')
) AS v(code, rule_type, description)
WHERE f.project_id = 1 AND f.name = 'core'
ON CONFLICT (feature_id, code) DO NOTHING;

COMMIT;

-- ── Comprobación ─────────────────────────────────────────────────────────────
SELECT m.id, m.username, m.member_type,
       string_agg(r.role_code, ', ' ORDER BY r.role_code) AS roles
FROM member m
LEFT JOIN member_role r ON r.member_id = m.id
WHERE m.id IN (3, 4)
GROUP BY m.id, m.username, m.member_type
ORDER BY m.id;

SELECT count(*) AS rules_totales,
       count(*) FILTER (WHERE code LIKE 'PRODUCTO-001%') AS producto_001
FROM business_rule;
