---
id: NAV-BY-DOMAIN
type: navigation
status: active
---

# Navegación por dominio

| Dominio | Mapa | Decisiones | Invariantes | Contratos | Implementación | Tests |
|---|---|---|---|---|---|---|
| Ingesta de archivos | [domains/ingestion.md](../domains/ingestion.md) | INGESTA-001, INGESTA-002, CORE-002, BASE-001 | INV-009..012, INV-030, INV-004 | [mapeo-ingesta](../contracts/mapeo-ingesta.md) | `db/actual/funciones/ingesta_*.sql`, `carga_*.sql`, `match_*.sql` · `bin/gen_wf_ingesta.py` | `pruebas.sh ingesta_sin_modelo carga_sin_perdida` |
| Conversación / router | [domains/conversation.md](../domains/conversation.md) | ROUTER-001, CONTENIDO-001, PLANES-001 | INV-018..021 | [router-evento](../contracts/router-evento.md) | `db/actual/funciones/router_*.sql` · `bin/gen_wf_router.py` | `db/pruebas/router_casos.sql` |
| Inteligencia / informe | [domains/intelligence.md](../domains/intelligence.md) | CORE-001, INFORME-001, HALLAZGOS-001, DATOS-001 | INV-001..003, 013..016, 027 | [hallazgos-prompt](../contracts/hallazgos-prompt.md) | `db/actual/funciones/{ejecucion_*,hallazgos_*,informe_*,validar_cifras,salud_negocio}.sql` · `bin/gen_wf_ejecutar.py` | `pruebas.sh aceptacion empty_state reglas_comparativas` |
| Recomendaciones | [domains/recommendations.md](../domains/recommendations.md) | CORE-003, CORE-001, ALERTAS-001 | INV-005, INV-022 | — | `db/actual/funciones/recomendacion*.sql` · `db/actual/tablas/recomendaciones.sql` | `pruebas.sh aceptacion reglas_comparativas` |
| Canales / entrega | [domains/channels.md](../domains/channels.md) | CONTENIDO-001, PRODUCTO-002 | INV-007, 019, 027 | [salida-wf-enviar](../contracts/salida-wf-enviar.md), [router-evento](../contracts/router-evento.md) | `bin/gen_wf_{router,wa_router,enviar}.py` · `resolver_plantilla`, `teclado_*`, `wa_*` | verificar.sh chequeo 1 (sólo reproducibilidad) |
| Portal | [domains/portal.md](../domains/portal.md) | PORTAL-001, BASE-001, PRODUCTO-002 | INV-017, INV-029 | [rpc-portal](../contracts/rpc-portal.md) | `db/actual/funciones/portal_*.sql` · `portal/Caddyfile` · `portal/publico/` | manual (agent-context/reference/seguridad.md §2) |
| Proactividad | [domains/proactivity.md](../domains/proactivity.md) | ALERTAS-001 | INV-022 | — | `mantenimiento_ciclo`, `alertas_evaluar`, `informes_periodicos_disparar` · `bin/gen_wf_cron.py` | manual (`/salud`, `/fallas`) |

Dominios menores sin mapa propio (cubierto por los de arriba): **matching**
(→ ingestion), **consulta en lenguaje natural** (→ conversation + intelligence),
**memoria/snapshots/conocimiento** (→ intelligence + `../../agent-context/reference/memoria-y-estado.md`),
**seguridad** (→ portal + `../../agent-context/reference/seguridad.md`).
