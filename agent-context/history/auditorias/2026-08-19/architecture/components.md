# Componentes internos

Un componente es aquí **una agrupación funcional de objetos de la base o de
workflows**, no un servicio desplegable. Chasqui tiene 4 servicios y ~10
componentes lógicos.

Nombres exactos verificados contra `pg_proc`, `pg_views`, `pg_class` y
`workflow_entity` el 2026-08-19.

---

## C1 · Canal de entrada

| | |
|---|---|
| Workflows | `wf_router` (10 nodos, activo, `triggerCount=1`), `wf_wa_router` (14 nodos, activo, `triggerCount=2`) |
| Generadores | `bin/gen_wf_router.py`, `bin/gen_wf_wa_router.py` |
| Funciones SQL | `usuario_de_canal`, `router_marcar_editables` |
| Entrada | webhook POST |
| Salida | items `{tipo: enviar\|ingerir\|ejecutar\|panel}` |

`[CONFIRMADO]` El evento se normaliza a la **misma** forma en los dos canales:
`{canal, from:{id,username}, chat:{id}, texto, tiene_documento, callback_id,
message_id, file_id, file_name, mime}`. Un toque de botón se normaliza al mismo
campo `texto` que un mensaje escrito, porque los `callback_data` **son** los
comandos. Por eso no hay dos máquinas de estados.

`[CONFIRMADO]` Telegram: el secreto `TELEGRAM_WEBHOOK_SECRET` queda **embebido**
en el nodo `Normalizar` al generar. Generar sin `.env` cargado aborta el script
a propósito.

`[CONFIRMADO]` WhatsApp: no verifica `X-Hub-Signature-256`. La defensa es la
ruta secreta más el filtro por `phone_number_id`. Está declarado como TODO en el
generador y en `docs/WHATSAPP.md`.

---

## C2 · Router (máquina de estados)

| | |
|---|---|
| Entrada | `router_procesar_mensaje(p_evento jsonb) -> jsonb` |
| Contexto | `router_ctx` |
| Handlers | `router_h_admin`, `router_h_comandos`, `router_h_sin_sesion`, `router_h_intake`, `router_h_recibiendo` |
| Salida | `router_respuesta(...)` → `{chat_id, respuestas[], acciones[]}` |

`[CONFIRMADO]` Orden de despacho, literal:

1. `router_h_admin` — antes de mirar la sesión, para que `/salud` no refresque
   `ultima_actividad`.
2. Se carga la sesión abierta (`cerrada_en IS NULL`, `ORDER BY id DESC LIMIT 1`)
   y se le refresca `ultima_actividad`.
3. `router_h_comandos` — lo que se contesta en cualquier paso.
4. Si no hay sesión → `router_h_sin_sesion`.
5. Si `estado='procesando'`: **con documento → acción `ingerir` igual**; sin
   documento → `ejecucion.ya_en_curso`. Esta rama es `INGESTA-002`.
6. Si `estado='intake'` → `router_h_intake`; si `='recibiendo'` →
   `router_h_recibiendo`.
7. Caída → `sistema.no_entendido`.

`[CONFIRMADO]` `ROUTER-001` («un handler por estado») se cumple: 6 funciones
independientes, ninguna migración reciente copia el router entero.

`[CONFIRMADO]` `router_h_comandos` mide 251 líneas y concentra: informativos,
módulos, consentimiento, tipo de negocio, acciones `rec:`, `/portal`, `/plan`,
`/saber`, `/cancelar`, `/nueva` y `svc:`. Es el handler más pesado del sistema.

---

## C3 · Presentación

| | |
|---|---|
| Funciones | `resolver_plantilla`, `teclado_markup`, `teclado_intake/_modulo/_modulos/_recomendacion/_recomendaciones/_tipos_negocio/_consentimiento`, `esc_html`, `limpiar_marcado`, `miles`, `fmt_decimal`, `unidades_es`, `mes_es`, `periodo_es`, `barra_10`, `semaforo` |
| Tabla | `plantillas` (82 filas, todas `canal='telegram'`) |
| Workflow | `wf_enviar` (49 nodos) |

`[CONFIRMADO]` `resolver_plantilla(clave, vars, teclado)` devuelve
`{texto, formato, teclado}`. Si la clave **no existe** devuelve la clave misma
escapada como cuerpo — ese es el mecanismo por el que `admin_reporte` entrega su
salida (le pasa el texto completo como si fuera una clave).

`[INFERIDO]` Efecto colateral: la salida de `/salud`, `/embudo`, etc. lleva
asteriscos de Markdown (`*Salud de ingesta*`) pero se manda con `parse_mode:
HTML`, así que el usuario ve los asteriscos literales. Sin impacto funcional.

`[CONFIRMADO]` Por qué `wf_enviar` tiene 49 nodos: el nodo de Telegram de n8n no
acepta un `reply_markup` armado por expresión. El generador documenta cinco
sondas contra la API real y la única forma que funciona es **forma literal del
teclado + expresiones sólo en las hojas**. De ahí un nodo por cantidad de filas,
duplicado para la rama de edición y otra vez para el panel.

---

## C4 · Carga y panel

| | |
|---|---|
| Funciones | `carga_evaluar`, `carga_panel`, `carga_resumen`, `carga_arrancar`, `carga_hay_con_que`, `carga_registrar_fallo`, `carga_panel_registrar` |
| Columnas de estado | `sesiones.panel_mensaje_id`, `.analisis_pedido_en`, `.panel_pedido_en`, `.contexto->'descargas_fallidas'` |

`[CONFIRMADO]` `carga_evaluar` es el árbitro: toma un
`pg_advisory_xact_lock(hashtextextended('carga_panel:'||sesion, 0))` (migración
076 corrigió la firma que la 075 dejó rota), y devuelve `nada` / `panel` /
`analizar`. Ningún nodo de n8n decide si el análisis arranca.

`[CONFIRMADO]` El debounce es doble: el nodo `Esperar` de n8n espera **11 s** y
`carga_evaluar` compara contra `parametros.carga_silencio_segundos` = **10**.
El comentario del generador explica el segundo de margen.

---

## C5 · Ingesta

| | |
|---|---|
| Workflow | `wf_ingesta` (34 nodos) |
| Funciones | 22 con prefijo `ingesta_*` |
| Tablas | `documentos`, `formatos_documento`, `movimientos`, `sinonimos_columna` |

Detalle completo en `../domains/ingestion.md`.

---

## C6 · Matching

| | |
|---|---|
| Funciones | `match_resolver_documento`, `match_resolver_producto`, `match_confirmar_alias`, `alias_pendientes`, `norm_texto` |
| Tablas | `productos`, `alias` |
| Vista | `v_calidad_matching` |
| Umbral | `parametros.match_umbral_trgm`, **no existe como fila** ⇒ cae al literal `0.45` |

`[CONTRADICCIÓN]` `match_resolver_producto` lee
`parametro(negocio, 'match_umbral_trgm')` pero esa clave **no está** en
`parametros` (35 filas verificadas). El umbral efectivo es el `coalesce` en el
código, no una fila. Contradice `CONTENIDO-001` («un umbral se cambia con un
INSERT»). Ya anotado como menor en `docs/auditoria_2026-08-19.md` A-09.

---

## C7 · Análisis

| | |
|---|---|
| Workflow | `wf_ejecutar` (29 nodos) |
| Funciones de hallazgos | `hallazgos_generar`, `hallazgos_compras`, `contexto_negocio_recuperar` — despachadas por `servicios.funcion_hallazgos` |
| Cálculo | `salud_negocio`, `recomendaciones_negocio`, `hallazgos_comparativo` |
| Render | `informe_render`, `informe_estructura_seca`, `informe_base_bloque`, `informe_salud_bloque` |
| Validación | `validar_cifras`, `cifra_norm`, `cifra_variantes` |
| Ciclo | `ejecucion_preparar`, `ejecucion_cerrar` |

`[CONFIRMADO]` El despacho es dinámico:
`EXECUTE format('SELECT %I($1,$2)', servicios.funcion_hallazgos)`, con un
`to_regprocedure` previo que falla la ejecución si la función no existe con
firma `(bigint, jsonb)`. Por eso `hallazgos_generar` y `hallazgos_compras`
tienen **dos** firmas cada una: la de dos argumentos es un envoltorio que ignora
el contexto.

---

## C8 · Memoria

| | |
|---|---|
| Snapshots | `snapshot_tomar`, `snapshot_anterior`, `snapshot_umbrales`, `snapshot_version` (=1), `snapshots_backfill` |
| Recomendaciones | `recomendaciones_registrar`, `recomendaciones_medir`, `recomendacion_accion`, `recomendacion_marcar_cierre`, `recomendacion_metrica_valor`, `recomendacion_objeto_evaluable`, `recomendaciones_vigentes` |
| Conocimiento | `conocimiento_guardar`, `conocimiento_buscar`, `conocimiento_pendiente_registrar` |

Detalle en `../memory-and-state.md`.

---

## C9 · Consulta

| | |
|---|---|
| Entrada | `consulta_iniciar` (desde `router_h_sin_sesion`) |
| Intención | `intencion_detectar`, `intencion_resolver`, `intencion_agregados`, `periodo_resolver` |
| Contexto | `contexto_negocio_recuperar`, `perfil_negocio`, `conocimiento_buscar` |
| Tablas | `intenciones` (7 filas), `conocimiento`, `conocimiento_pendiente` |

`[CONFIRMADO]` La detección de intención es **léxica**, no del LLM:
`intenciones.patrones text[]` se compara con `LIKE` contra `norm_texto` de la
pregunta y gana la que más patrones acierte.

---

## C10 · Proactividad

| | |
|---|---|
| Workflow | `wf_cron` (6 nodos, `triggerCount=1`, cada 5 min) |
| Funciones | `mantenimiento_ciclo`, `alertas_evaluar`, `informes_periodicos_disparar` |
| Vistas | `v_negocios_alertables`, `v_negocios_informe_periodico` |
| Tabla | `alertas_enviadas` |

`[CONFIRMADO]` `mantenimiento_ciclo` hace cuatro cosas y las tres últimas están
envueltas en `BEGIN … EXCEPTION` que escribe en `fallas`: el reaper de
ejecuciones colgadas es lo único que no puede dejar de correr.

---

## C11 · Portal

| | |
|---|---|
| Servicios | `postgrest`, `proxy` |
| Funciones expuestas | 27 a `portal_usuario` + 2 a `portal_anon` (`portal_sesion_abrir`, `portal_cotizacion_publica`) |
| No expuestas | `portal_claim`, `portal_negocio`, `portal_mov_nombre`, `portal_token_crear` |
| Frontend | `portal/publico/index.html` (47 KB, sin build, sin framework) + `cotizacion.html` |

Detalle en `../interfaces/api.md` y `../security.md`.

---

## C12 · Errores

| | |
|---|---|
| Workflow | `wf_error` (6 nodos), declarado `errorWorkflow` de los otros 6 por `wf_lib.WF.dump()` |
| Tabla | `fallas` |

`[CONFIRMADO]` Clasifica `transitoria` con un regex sobre el mensaje:
`/timeout|ETIMEDOUT|ECONNRESET|429|rate.?limit|EAI_AGAIN|socket hang up/i`.
Avisa por plantilla `falla.aviso_admin` a `usuarios WHERE rol='admin'`.

`[CONFIRMADO]` En esta instalación **no hay ningún usuario con rol `admin`**
(el único usuario es `operador`), así que el aviso de falla no llega a nadie.
Es el hallazgo A-05 de `docs/auditoria_2026-08-19.md`, confirmado de nuevo aquí.

## Diagrama

Ver `diagrams/components.mmd`.
