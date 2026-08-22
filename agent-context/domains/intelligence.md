---
id: DOMAIN-INTELIGENCIA
type: domain
status: active
implemented_in: [db/actual/funciones/ejecucion_*.sql, db/actual/funciones/hallazgos_*.sql, db/actual/funciones/informe_*.sql, db/actual/funciones/validar_cifras.sql, db/actual/funciones/salud_negocio.sql, bin/gen_wf_ejecutar.py]
---

# Inteligencia (hallazgos → informe entregado)

**Propósito**: de datos almacenados a un texto en el chat: métricas, salud,
reglas priorizadas, redacción LLM auditada, memoria dejada al cerrar.

| | |
|---|---|
| **Entry points** | acción `{tipo:'ejecutar'}` → `wf_ejecutar` (29 nodos); también `wf_cron` y `wf_ingesta` lo disparan (siempre NO-wait) |
| **Entradas** | `ejecuciones.id` en `preparando` (+`chat_id`) |
| **Salidas** | `ejecuciones.texto/.hallazgos`, mensajes chat, `snapshots_negocio`, `recomendaciones`, medición |
| **Tablas primarias** | `ejecuciones`, `prompts`, `servicios`, vistas del análisis (`mov_visibles`, `v_margen_producto`, `v_rotacion_producto`, `v_deriva_costo`, `v_pareto_utilidad`), `snapshots_negocio` |
| **Funciones primarias** | `ejecucion_preparar` · `salud_negocio` · `recomendaciones_negocio` (11 reglas, 683 líneas) · `informe_render` · `validar_cifras` · `informe_estructura_seca` · `ejecucion_cerrar` |

**Contratos**: [`../contracts/hallazgos-prompt.md`](../contracts/hallazgos-prompt.md) — la frontera SQL/LLM.
**Decisiones**: `CORE-001`, `INFORME-001`, `HALLAZGOS-001`, `DATOS-001`, `PRODUCTO-002`.
**Invariantes**: INV-001…INV-003, INV-013…INV-017.
**Tests**: `bash bin/pruebas.sh aceptacion empty_state reglas_comparativas`; E2E.

## Reparto SQL / modelo `[CONFIRMADO]`

| Pieza | Quién |
|---|---|
| impacto $, precio sugerido, cantidad a comprar, proveedor más barato | **SQL** (`recomendaciones_negocio`) |
| textos problema/impacto/opciones ya redactados; prioridad y orden | **SQL** |
| titular y reescritura | modelo (sólo puede empeorar, no inventar cifras: INV-002) |
| layout HTML, semáforo, bloque "sobre qué datos hablo" | **SQL** (`informe_render` + plantillas `informe.*`) |
| troceo ≤3800 y elección de plantilla por posición | n8n JS (`RespFinal`) — excepción viva a la tesis (DISC-C9) |

## Salud (seis notas, HALLAZGOS-001)

`ventas, margenes, inventario, compras, riesgos, liquidez` — cada una NULL sin
datos; NULL no promedia ni se rellena; seis NULL ⇒ salud NULL. El índice alto
sobre pocas notas no es negocio sano: el informe declara su base (INV-016).

## Degradación (ningún usuario sin respuesta)

```text
LLM ok → narrado | truncado/JSON inválido/cifra inventada → 1 reintento
→ sigue mal → informe seco (misma render, sin narración)
cupo mensual agotado → estado 'bloqueada', cero tokens
colgada >15 min → reaper del cron → 'fallida'
```

## Presupuesto de tiempo `[MEDIDO]`

`hallazgos_generar` ≈ 95 s + cierre ≳50 s contra techo `EXECUTIONS_TIMEOUT=300`.
El camino con reintento probablemente no cabe (A-02). Cambiar esto es tocar
`docker-compose.yml`, no SQL.

## Trampas registradas

- `mercado_compras`: su función no produce `recomendaciones` pero
  `ejecucion_cerrar` registra las reglas de ventas igualmente; su prompt describe
  otro producto (DISC-A5/A6).
- `informes_periodicos_disparar`: respeta franja 8–20 America/Bogota, ≥30 días
  desde último análisis, ≥10 movimientos nuevos.
- `narrado` no se persiste: desde la base no se sabe cuántos informes salieron
  secos (DISC-I7).
