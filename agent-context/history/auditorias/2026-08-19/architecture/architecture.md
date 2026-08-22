# Arquitectura real

Foto del **2026-08-19**. Cada afirmación lleva su evidencia.

## 1. Procesos que existen

`[CONFIRMADO]` `docker compose ps` sobre el proyecto `chasqui`:

| Contenedor | Imagen | Puertos | Perfil |
|---|---|---|---|
| `chasqui-postgres-1` | `postgres:16` (16.14) | `127.0.0.1:5432` | siempre |
| `chasqui-n8n-1` | `n8nio/n8n:2.31.5` | `127.0.0.1:5678` | siempre |
| `chasqui-postgrest-1` | `postgrest/postgrest:v12.2.12` | ninguno publicado | siempre |
| `chasqui-proxy-1` | `caddy:2-alpine` | `127.0.0.1:8080` → `:80` | siempre |
| `chasqui-cloudflared-1` | `cloudflare/cloudflared:latest` | — | `local` |
| `chasqui-registrador-1` | `alpine:3.20` | — | `local` |

`[CONFIRMADO]` Gotenberg **no está** en `docker-compose.yml`. La generación de
PDF está fuera del camino (`PRODUCTO-002`), aunque la columna `ejecuciones.pdf`
sigue existiendo y `ejecucion_cerrar` la preserva.

`[CONFIRMADO]` Dos bases lógicas en la misma instancia: `chasqui` (negocio y
producto) y `n8n` (runtime de workflows). Creadas por `db/init/00_bases.sh` en
el primer arranque.

## 2. Quién llama a quién

`[CONFIRMADO]`, leído de los generadores (que son la fuente; los JSON son
generados y `bin/verificar.sh` chequeo 1 los reproduce byte a byte):

```
Telegram ──POST──► Caddy /webhook/telegram ──► n8n: wf_router
                                                 │
                                                 ├─ SELECT router_marcar_editables(
                                                 │      router_procesar_mensaje(ev), ev)
                                                 │
                                                 └─ Switch por acción:
                                                    enviar   ──► wf_enviar   (espera)
                                                    ingerir  ──► wf_ingesta  (espera)
                                                    ejecutar ──► wf_ejecutar (NO espera)
                                                    panel    ──► wf_enviar   (espera)

wf_ingesta ── descarga Telegram/WhatsApp ─► ingesta_registrar_documento
           ├─ documento (DIAN XML) ─► ingesta_procesar_documento ─► ingesta_parsear_dian
           │                                                     └─► cartera_facturar_dian
           └─ tabla ─► extractFromFile ─► ingesta_identificar_tabular
                        ├─ huella conocida ────────────────────────► ingesta_cargar_tabular
                        ├─ diccionario resuelve ─► ingesta_registrar_formato_resuelto ─► "
                        └─ ni fecha ni valor ─► LLM ─► ingesta_registrar_formato_inferido ─► "
           ── match_resolver_documento ── ingesta_resumen_documento
           ── wait 11 s ── carga_evaluar
                        ├─ 'panel'    ─► wf_enviar (rama panel)
                        ├─ 'analizar' ─► wf_enviar (panel) + wf_ejecutar (NO espera)
                        └─ 'nada'     ─► fin

wf_ejecutar ── canal_de_chat ── ejecucion_preparar (hallazgos + prompt + cupo)
            ── LLM (intento 1) ── informe_render ── validar_cifras
            ── si falla: LLM (intento 2) ── render ── validar
            ── si vuelve a fallar: informe_estructura_seca ── render
            ── ejecucion_cerrar (snapshot + recomendaciones + medición)
            ── wf_enviar  ("EntregarInforme", el propio wf_ejecutar entrega)

wf_cron (5 min) ── mantenimiento_ciclo()
                   ├─ notificaciones[] ─► wf_enviar (mode: each)
                   └─ ejecuciones[]    ─► wf_ejecutar (mode: each)

wf_error (errorWorkflow de los otros 6) ── INSERT fallas ── wf_enviar a admins
```

`[CONFIRMADO]` `wf_enviar` es el **único** nodo del sistema que habla con
Telegram para mandar mensajes. Todos los demás workflows lo invocan.

`[CONFIRMADO]` Punto de diseño explícito: `wf_router` y `wf_ingesta` disparan
`wf_ejecutar` con `waitForSubWorkflow: false`, y **wf_ejecutar entrega su propio
informe**. El comentario en `bin/gen_wf_ejecutar.py` documenta la causa medida:
`EXECUTIONS_TIMEOUT=300` empieza a contar cuando entra el archivo, y un informe
ya generado se perdió por eso.

## 3. Responsabilidades por componente

| Operación | Dónde ocurre | Evidencia |
|---|---|---|
| Máquina de estados de la conversación | Postgres | `router_procesar_mensaje` + 5 handlers |
| Textos, botones, formato | Postgres | `plantillas` (82 filas) + `resolver_plantilla` + `teclado_markup` |
| Parseo de XML DIAN | Postgres | `ingesta_parsear_dian` con `XMLTABLE` |
| Extracción de filas de CSV/XLSX | **n8n** | nodo `extractFromFile`; Postgres no puede leer un xlsx |
| Detección del delimitador CSV | **n8n** | nodo `DetectarSeparador` (JS) |
| Mapeo de columnas → canónicas | Postgres primero, LLM sólo si falla | `ingesta_resolver_columnas` (44 sinónimos) → `ingesta_inferir_mapeo_sql`; LLM sólo si no hay fecha o no hay valor |
| Conversión de cifras y fechas | Postgres | `ingesta_num`, `ingesta_fecha` |
| Matching de productos | Postgres | `match_resolver_documento` / `match_resolver_producto` (código de barras → alias exacto → trigram ≥ 0,45 → pendiente) |
| Métricas y salud | Postgres | `salud_negocio`, 22 vistas |
| Reglas de negocio y prioridad | Postgres | `recomendaciones_negocio` |
| Redacción del informe | LLM | `prompts` id 4 y 5 |
| Layout del informe | Postgres | `informe_render` (235 líneas) + `plantillas` `informe.*` |
| Validación de cifras | Postgres | `validar_cifras` |
| Partido del informe en mensajes | **n8n** | nodo `RespFinal` (JS), límite `LIM = 3800` |
| Reintentos y backoff HTTP | n8n | `retryOnFail` en los nodos |
| Persistencia de memoria | Postgres | `snapshot_tomar`, `recomendaciones_registrar`, `recomendaciones_medir` |

`[CONTRADICCIÓN]` La tesis de `AGENTS.md` dice «nada de aritmética ni reglas de
negocio en los nodos». Hay lógica de producto residual en JS de n8n: el troceado
a 3800 caracteres y la elección de plantilla por posición (`gen_wf_ejecutar.py`,
nodo `RespFinal`), el aplanado del teclado con `MAX_FILAS = 6` duplicado con
`parametros.teclado_max_filas`, la espera literal de 11 s en `wf_ingesta`, y la
clasificación transitoria/permanente por regex en `wf_error`. Está ya registrado
en `docs/historico/auditorias/2026-08.md`; se repite aquí porque sigue vigente.

## 4. Dónde se almacena cada cosa

| Información | Tabla / soporte | Fuente de verdad |
|---|---|---|
| Archivo original del usuario | `documentos.contenido` (bytea) | **sí**, es el único original |
| Movimientos normalizados | `movimientos` | derivado de `documentos` |
| Productos, alias, terceros | `productos`, `alias`, `terceros` | derivado del matching |
| Facturas y saldos | `facturas`, `pagos` | derivado de DIAN + pagos del portal |
| Conteos de inventario | `conteos_inventario` | **sí**, lo declara el dueño |
| Conocimiento del negocio | `conocimiento` | **sí**, lo escribe el dueño |
| Estado de la conversación | `sesiones` | **sí** |
| Resultado de un análisis | `ejecuciones.hallazgos` + `.texto` | snapshot inmutable de esa corrida |
| Foto del negocio | `snapshots_negocio` | derivado, con `version` y `umbrales` congelados |
| Recomendaciones | `recomendaciones` | **sí** para el estado; las cifras se refrescan |
| Producto (textos, umbrales, prompts) | 12 tablas de contenido | **sí**, entra por migración |
| Workflows y credenciales | base `n8n` | **sí** para credenciales; los workflows son generados desde `bin/gen_wf_*.py` |

## 5. Cómo entran los datos y cómo salen los resultados

`[CONFIRMADO]` **Entrada**: sólo dos puertas. (a) archivos y texto por
Telegram/WhatsApp; (b) formularios del portal (conteos, facturas, pagos,
conocimiento, cotizaciones, confirmación de alias). No hay importación por API,
ni carga masiva, ni conector a un ERP.

`[CONFIRMADO]` **Salida**: sólo tres. (a) mensajes de chat por `wf_enviar`;
(b) lecturas del portal vía funciones `portal_*`; (c) `ejecuciones.texto` en la
base. **No hay PDF, no hay correo, no hay export.**

## 6. Configuración que gobierna el runtime

`[CONFIRMADO]` en `docker-compose.yml`:

| Variable | Valor | Consecuencia observable |
|---|---|---|
| `N8N_CONCURRENCY_PRODUCTION_LIMIT` | 5 | freno de estampida; con 101 archivos las ejecuciones se encolan |
| `EXECUTIONS_TIMEOUT` | 300 s | techo duro de una ejecución; ver §análisis en `domains/intelligence.md` |
| `EXECUTIONS_TIMEOUT_MAX` | 900 s | — |
| `EXECUTIONS_DATA_SAVE_ON_SUCCESS` | `none` | **una ejecución exitosa no deja rastro en n8n**; sólo se guardan errores |
| `EXECUTIONS_DATA_MAX_AGE` | 168 h | los errores se podan a los 7 días |
| `N8N_DEFAULT_BINARY_DATA_MODE` | `filesystem` | binarios al volumen `n8n_data` |
| `PGRST_DB_MAX_ROWS` | 1000 | tope de filas del portal |
| `PGRST_OPENAPI_MODE` | `disabled` | PostgREST no publica su esquema |

`[INFERIDO]` `EXECUTIONS_DATA_SAVE_ON_SUCCESS=none` es la razón por la que un
fallo silencioso (por ejemplo un `onError: continueRegularOutput` mal puesto) es
prácticamente invisible: no queda ejecución que abrir.

## Diagrama

Ver `diagrams/architecture.mmd`.
