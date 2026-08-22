---
id: ARCH-DATAFLOW
type: architecture
status: active
---

# Flujo de datos

## Puertas de entrada y salida `[CONFIRMADO]`

- **Entran** sólo por: (a) chat Telegram/WhatsApp (texto, botones, archivos);
  (b) formularios del portal (conteos, facturas, pagos, conocimiento,
  cotizaciones, alias). No hay API de ingesta ni conectores.
- **Salen** sólo por: (a) mensajes de chat (`wf_enviar`, único emisor);
  (b) lecturas RPC del portal; (c) `ejecuciones.texto` en la base.
  Sin PDF, sin correo, sin export (`PRODUCTO-002`).

## Los cuatro flujos

### 1. Mensaje → respuesta (sincrónico)
```text
Telegram → Caddy → wf_router → Normalizar(secreto) 
  → SQL: router_marcar_editables(router_procesar_mensaje(ev), ev)
  → {respuestas[], acciones[]} → Switch por tipo:
      enviar/panel → wf_enviar (espera)   · ingerir → wf_ingesta (espera)
      ejecutar → wf_ejecutar (NO espera)
```
Contrato: [`../contracts/router-evento.md`](../contracts/router-evento.md) y
[`../contracts/salida-wf-enviar.md`](../contracts/salida-wf-enviar.md).

### 2. Archivo → movimientos (ingesta)
```text
descarga (3 reintentos) → ingesta_registrar_documento (SIEMPRE inserta bytea)
  ├─ DIAN XML → ingesta_parsear_dian (XMLTABLE) + cartera_facturar_dian
  └─ tabular → extraer filas (n8n) → ingesta_identificar_tabular (huella→
       diccionario→LLM sólo si no hay fecha o valor) → ingesta_cargar_tabular
       (compuerta ≤20% nulos; cero filas si falla)
→ match_resolver_documento → Esperar 11s → carga_evaluar (lock):
      panel | analizar(→wf_ejecutar) | nada
```
Secuencia completa: [`diagrams/sequences/ingesta.mmd`](diagrams/sequences/ingesta.mmd).
Dominio: [`../domains/ingestion.md`](../domains/ingestion.md).

### 3. Ejecución → informe (análisis)
```text
ejecucion_preparar (cupo→hallazgos→prompt activo) → LLM intento 1
→ informe_render → validar_cifras → ¿ok? no→intento 2 → no→informe seco
→ ejecucion_cerrar (snapshot + registrar recomendaciones + medir)
→ wf_enviar entrega el informe (el propio wf_ejecutar entrega; NO quien lo llamó)
```
Secuencia: [`diagrams/sequences/ejecutar-informe.mmd`](diagrams/sequences/ejecutar-informe.mmd).
Contrato: [`../contracts/hallazgos-prompt.md`](../contracts/hallazgos-prompt.md).

### 4. Cron (cada 5 min)
`mantenimiento_ciclo()`: ①reaper de ejecuciones colgadas (>15 min) ②expira
sesiones (24 h) ③alertas (`alertas_evaluar`, cooldown/franja/prioridad alta)
④informes periódicos. Fan-out a `wf_enviar` / `wf_ejecutar` en mode:each.

## Dónde vive cada dato

| Dato | Soporte | Fuente de verdad |
|---|---|---|
| archivo original | `documentos.contenido` bytea | sí (único original; nada en disco) |
| movimientos normalizados | `movimientos` | derivado; el análisis lee **`mov_visibles`** |
| productos/alias/terceros | `productos`,`alias`,`terceros` | derivado del matching/DIAN |
| conteos y conocimiento | `conteos_inventario`,`conocimiento` | lo declara el dueño |
| estado conversación | `sesiones` | sí; expira 24 h |
| resultado de análisis | `ejecuciones.hallazgos/.texto` | snapshot inmutable de la corrida |
| foto diaria | `snapshots_negocio` | derivado, congela umbrales |
| recomendaciones | `recomendaciones` | estado sí; cifras se refrescan |
| producto (textos/umbrales/prompts) | 12 tablas de contenido | entra sólo por migración |

Todo el análisis se **recalcula en cada lectura**: no hay una sola tabla
materializada ni cache (`hallazgos_generar` ≈ 95 s sobre 37k movimientos).
Detalle: `../../agent-context/reference/memoria-y-estado.md`.
