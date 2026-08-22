# Historia de implementación — sin regla propia

Estas 29 migraciones construyen o arreglan algo sin enunciar una regla nueva
que un cambio futuro pudiera violar: son el cómo se llegó acá.

Varias sí llevan una regla, pero ya está promovida a una de las siete decisiones
vigentes; se anota entre paréntesis cuál.

Lo que estas migraciones documentan —qué existe y cómo funciona— ya está en
`db/actual/INDICE.md`, que además está al día y el archivo no.

**No requieren revisión.** Se listan para que quede constancia de que se miraron
y se decidió que no aportan una decisión.

**29 migraciones.** Extraído de `decisiones/candidatos/` el 2026-08-18.

| migración | de qué trata |
|---|---|
| [`001_nucleo.sql`](../../agent-context/history/migraciones/001_nucleo.sql) | tablas base |
| [`004_ingesta.sql`](../../agent-context/history/migraciones/004_ingesta.sql) | registro y parseo |
| [`005_matching.sql`](../../agent-context/history/migraciones/005_matching.sql) | matching a producto |
| [`006_calculos.sql`](../../agent-context/history/migraciones/006_calculos.sql) | aritmética en vistas (→CORE-001) |
| [`008_ejecucion_operacion.sql`](../../agent-context/history/migraciones/008_ejecucion_operacion.sql) | motor de ejecución |
| [`009_fix_validar_cifras.sql`](../../agent-context/history/migraciones/009_fix_validar_cifras.sql) | fix de puntuación |
| [`012_router.sql`](../../agent-context/history/migraciones/012_router.sql) | primer router |
| [`014_mantenimiento_notif.sql`](../../agent-context/history/migraciones/014_mantenimiento_notif.sql) | reaper de notificaciones |
| [`015_router_admin.sql`](../../agent-context/history/migraciones/015_router_admin.sql) | comandos de admin |
| [`016_fix_jsonb_literales.sql`](../../agent-context/history/migraciones/016_fix_jsonb_literales.sql) | fix de literales jsonb |
| [`019_ingesta_encadenado.sql`](../../agent-context/history/migraciones/019_ingesta_encadenado.sql) | encadenar ingesta |
| [`026_fix_cifras_miles.sql`](../../agent-context/history/migraciones/026_fix_cifras_miles.sql) | fix separador de miles |
| [`030_servicio_consulta.sql`](../../agent-context/history/migraciones/030_servicio_consulta.sql) | servicio consulta |
| [`033_portal.sql`](../../agent-context/history/migraciones/033_portal.sql) | portal (→PORTAL-001) |
| [`034_ejecucion_privada.sql`](../../agent-context/history/migraciones/034_ejecucion_privada.sql) | funciones privadas (→PORTAL-001) |
| [`039_funciones_privadas_de_verdad.sql`](../../agent-context/history/migraciones/039_funciones_privadas_de_verdad.sql) | cierre real de privadas (→PORTAL-001) |
| [`043_mercado_compras.sql`](../../agent-context/history/migraciones/043_mercado_compras.sql) | segundo servicio: compras |
| [`053_historia_completa.sql`](../../agent-context/history/migraciones/053_historia_completa.sql) | historia completa (→CORE-002) |
| [`057_limpieza.sql`](../../agent-context/history/migraciones/057_limpieza.sql) | limpieza de muertos |
| [`058_snapshot_negocio.sql`](../../agent-context/history/migraciones/058_snapshot_negocio.sql) | snapshots |
| [`059_recomendaciones_persistentes.sql`](../../agent-context/history/migraciones/059_recomendaciones_persistentes.sql) | recomendaciones persistentes (→CORE-003) |
| [`060_reglas_comparativas.sql`](../../agent-context/history/migraciones/060_reglas_comparativas.sql) | reglas comparativas |
| [`061_perfil_negocio.sql`](../../agent-context/history/migraciones/061_perfil_negocio.sql) | perfil consolidado |
| [`062_consulta_sobre_numeros.sql`](../../agent-context/history/migraciones/062_consulta_sobre_numeros.sql) | consulta sobre números |
| [`063_intenciones_consulta.sql`](../../agent-context/history/migraciones/063_intenciones_consulta.sql) | intenciones |
| [`064_acciones.sql`](../../agent-context/history/migraciones/064_acciones.sql) | acciones sobre la recomendación |
| [`065_pedido.sql`](../../agent-context/history/migraciones/065_pedido.sql) | lista de pedido |
| [`066_resultado.sql`](../../agent-context/history/migraciones/066_resultado.sql) | medición del resultado (→CORE-003) |
| [`068_informe_periodico.sql`](../../agent-context/history/migraciones/068_informe_periodico.sql) | informe periódico |
