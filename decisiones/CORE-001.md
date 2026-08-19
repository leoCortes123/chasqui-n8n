---
id: CORE-001
dominio: core
estado: vigente
fecha: 2026-08-14
titulo: Postgres calcula, el LLM interpreta y redacta
invariantes:
  - ninguna cifra, umbral, regla financiera ni priorización puede vivir en un prompt
  - ninguna cifra del informe puede derivarse de la salida del modelo
  - toda cifra del informe existe en los hallazgos antes de llamar al modelo
  - está prohibido mover al LLM responsabilidades que hoy son de SQL; la dirección permitida es la contraria
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: [CORE-004]
implementada_en: [docs/historico/migraciones/008_ejecucion_operacion.sql, docs/historico/migraciones/009_fix_validar_cifras.sql, docs/historico/migraciones/026_fix_cifras_miles.sql, docs/historico/migraciones/047_informe_prescriptivo.sql, docs/historico/migraciones/055_impacto_tipado.sql]
afecta: [validar_cifras, informe_render, hallazgos_generar, recomendaciones_negocio]
procedencia: R-I de AGENTS.md, originalmente docs/historico/AUDITORIA_2026-08.md §0
---

## Problema medido

Un modelo que calcula produce cifras plausibles y falsas. En un producto cuyo
valor es decirle a un negocio dónde está perdiendo plata, una cifra inventada no
es un error de formato: destruye la única razón por la que alguien lo usaría.

## Decisión

Postgres hace todo lo determinístico —parseo, normalización, matching, cálculo,
máquina de estados, decisiones. El LLM sólo redacta sobre cifras que ya existen.
`validar_cifras` rechaza cualquier número del texto generado que no esté en los
hallazgos, y el reintento no lo ablanda.

## Alternativas descartadas

Dejar que el modelo calcule y validar después con tolerancia. Se descartó: una
tolerancia es una licencia para equivocarse dentro de un margen, y no hay margen
aceptable en "usted perdió X".

## Consecuencias

`bin/verificar.sh` corre los bancos que ejercitan `validar_cifras`. Cualquier
propuesta que mueva lógica de SQL a un prompt contradice esta decisión y
requiere una que la superseda.
