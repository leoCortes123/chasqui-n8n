---
id: NAV-BY-COMPONENT
type: navigation
status: active
---

# Navegación por componente

Componente → propósito → archivos → dependencias → consumidores → documentación.
Grafo completo función a función: [`../generated/symbols.json`](../generated/symbols.json),
tabla-a-funciones en [`../generated/dependencies.json`](../generated/dependencies.json).

## Workflows n8n (generados; fuente = `bin/gen_wf_*.py`)

| Workflow | Propósito | Llama (SQL) | Sub-workflows | Detalle |
|---|---|---|---|---|
| `wf_router` (10 nodos) | entrada Telegram | `router_marcar_editables(router_procesar_mensaje)` | enviar, ingesta, ejecutar(NO-wait) | [../contracts/router-evento.md](../contracts/router-evento.md) |
| `wf_wa_router` (14) | entrada WhatsApp (no operativo) | `router_procesar_mensaje` | idem + EnviarInforme (duplicaría entrega, DISC-I3) | [../domains/channels.md](../domains/channels.md) |
| `wf_ingesta` (34) | binario→movimientos | registrar_documento, identificar_tabular, cargar_tabular, match_resolver_documento, carga_evaluar… | enviar(panel), ejecutar(NO-wait) | [../domains/ingestion.md](../domains/ingestion.md) |
| `wf_ejecutar` (29) | motor de análisis genérico | canal_de_chat, ejecucion_preparar, informe_render×3, validar_cifras×2, estructura_seca, ejecucion_cerrar | enviar(EntregarInforme) | [../contracts/hallazgos-prompt.md](../contracts/hallazgos-prompt.md) |
| `wf_enviar` (49) | ÚNICA salida al canal | resolver_plantilla, canal_de_chat, wa_payload/texto, carga_panel(+registrar) | — | [../contracts/salida-wf-enviar.md](../contracts/salida-wf-enviar.md) |
| `wf_cron` (6) | mantenimiento+proactividad | mantenimiento_ciclo | enviar(each), ejecutar(each) | [../domains/proactivity.md](../domains/proactivity.md) |
| `wf_error` (6) | errorWorkflow de los otros 6 | INSERT fallas (literal), SELECT admins | enviar | DISC-C9 |

## Familias SQL (`db/actual/funciones/`)

| Prefijo/familia | Qué hace | Depende de | La consumen |
|---|---|---|---|
| `router_*` (12) | máquina de estados y despacho | sesiones, usuarios, identidades, plantillas | wf_router/wf_wa_router |
| `carga_*` (7) | árbitro del fin-de-silencio y panel | sesiones, documentos, parametros | wf_ingesta, wf_enviar |
| `ingesta_*` (22) | registro, huella, mapeo, carga, resumen | documentos, formatos_documento, sinonimos_columna, movimientos | wf_ingesta |
| `match_*` + `norm_*` (5) | resolución de productos y normalización | productos, alias | ingesta, portal |
| `hallazgos_*`, `informe_*`, `salud_negocio`, `validar_cifras` | cálculo→redacción→auditoría | vistas v_*, snapshots, parametros | wf_ejecutar |
| `recomendacion(es)_*` (8) | reglas, persistencia, cierre, medición | mov_visibles, metricas_resultado, parametros | ejecucion_cerrar, router, portal, cron |
| `snapshot_*` (4) | foto diaria con umbrales congelados | vistas v_* | ejecucion_cerrar, hallazgos_comparativo |
| `conocimiento_*` (3) | KB del dueño y pendientes | conocimiento(_pendiente) | consulta_iniciar, portal, recomendacion_accion |
| `intencion_*`, `periodo_resolver`, `consulta_iniciar` | pregunta→agregados SQL | intenciones, mov_visibles | router_h_sin_sesion |
| `portal_*` (32) | RPC del portal | JWT/GUC, tablas de negocio | PostgREST |
| `plantilla_*`, `teclado_*`, formato (`esc_html`,`miles`,`fmt_decimal`,`semaforo`,`barra_10`) | presentación | plantillas, parametros | router, wf_enviar, informes |
| `mantenimiento_ciclo`, `alertas_evaluar`, `informes_periodicos_disparar` | proactividad | alertas_enviadas, vistas selectoras | wf_cron |
| `usuario_de_canal`, `canal_de_chat`, `chat_de_usuario` | abstracción de canal | usuarios, identidades | todos los routers, wf_ejecutar/enviar |

## Servicios de infraestructura

| Componente | Archivos | Documentación |
|---|---|---|
| Caddy | `portal/Caddyfile` | [../architecture/containers.md](../architecture/containers.md) |
| PostgREST | compose + roles (`bin/preparar-portal.sh`) | [../contracts/rpc-portal.md](../contracts/rpc-portal.md) |
| Portal HTML | `portal/publico/index.html`, `cotizacion.html` | [../domains/portal.md](../domains/portal.md) |
| registrador/cloudflared | `docker-compose.yml`, `bin/registrar-webhook.sh` | README §arrancar prueba |
| Generadores | `bin/gen_wf_*.py`, `bin/wf_lib.py`, `bin/gen_estado_sql.sh`, `bin/gen_base.sh` | [../invariants/INVARIANTES.md](../invariants/INVARIANTES.md) INV-025 |
