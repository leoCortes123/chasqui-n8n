---
id: DOMAIN-INGESTA
type: domain
status: active
depends_on: [DOMAIN-CONVERSACION]
implemented_in: [db/actual/funciones/ingesta_*.sql, db/actual/funciones/carga_*.sql, db/actual/funciones/match_*.sql, bin/gen_wf_ingesta.py]
---

# Ingesta (archivos → movimientos con producto)

**Propósito**: del archivo que suelta el usuario a filas en `movimientos` con
producto resuelto, contadas en un solo panel.

| | |
|---|---|
| **Entry points** | acción `{tipo:'ingerir'}` desde `router_procesar_mensaje` (todo archivo, en cualquier estado — INV-009); `wf_ingesta` (34 nodos) |
| **Entradas** | binario Telegram (`file_id`) o WhatsApp; `{evento, sesion_id, chat_id}` |
| **Salidas** | `documentos` (siempre), `movimientos`, `productos`, `alias`, `terceros`, `facturas`; acciones `panel`/`analizar` |
| **Tablas primarias** | `documentos`, `formatos_documento`, `sinonimos_columna`, `movimientos` (+trigger plan), `alias`, `sesiones` |
| **Funciones primarias** | `ingesta_registrar_documento` · `ingesta_identificar_tabular` · `ingesta_cargar_tabular(_detalle)` · `match_resolver_documento/producto` · `carga_evaluar` (árbitro) · `carga_arrancar` |
| **Dependencias** | DOMAIN-CONVERSACION (sesión); LLM sólo para mapeo de columnas nuevo |
| **Consumida por** | DOMAIN-INTELIGENCIA (los datos), DOMAIN-PROACTIVIDAD (`carga_hay_con_que`) |

**Contratos**: [`../contracts/mapeo-ingesta.md`](../contracts/mapeo-ingesta.md) (n8n↔SQL↔LLM).
**Decisiones**: `INGESTA-001`, `INGESTA-002`, `CORE-002`, `BASE-001` (formatos aprendidos no entran al baseline).
**Invariantes**: INV-009…INV-012 ([`../invariants/INVARIANTES.md`](../invariants/INVARIANTES.md)).
**Tests**: `bash bin/pruebas.sh ingesta_sin_modelo carga_sin_perdida`; E2E `bin/prueba_ciclo_vida.py`.

## Implementación canónica

```text
wf_ingesta: bin/gen_wf_ingesta.py          (el JSON es generado)
registro:   db/actual/funciones/ingesta_registrar_documento.sql
layout:     ingesta_huella → ingesta_identificar_tabular
              escalón a) huella conocida (0 costo)
              b) diccionario sinonimos_columna + inferencia SQL (0 costo)
              c) prompt prompts_tecnicos 'ingesta.inferir_mapeo' (1 llamada)
carga:      ingesta_cargar_tabular_detalle (compuerta antes de insertar)
matching:   código de barras → alias exacto → trigram ≥0,45 → pendiente
panel:      carga_evaluar (pg_advisory_xact_lock) → nada|panel|analizar
```

## Lo que un agente suele romper

- Editar `workflows/wf_ingesta.json` en vez del generador (INV-026).
- Insertar movimientos directo en vez de por la ruta real.
- Asumir que `formatos_documento.origen='inferido'` implica "usó el modelo" —
  también lo escribe el camino del diccionario (DISC-D4).
- Olvidar que la compuerta de calidad rechaza el documento **entero**
  (>20% filas sin fecha/valor ⇒ estado `error`, cero filas).
- Llamar `ingesta_identificar_tabular` sin muestra: devuelve mapeo sin fecha ni
  separador inferidos. Todos los llamadores pasan las primeras 100 filas.
- Ruta muerta conocida: `ingesta_cargar_inventario` no es alcanzable desde el
  chat (DISC-I5). Conteos sólo por portal.

Flujo paso a paso verificado: [`../architecture/diagrams/sequences/ingesta.mmd`](../architecture/diagrams/sequences/ingesta.mmd)
y `../../agent-context/history/auditorias/2026-08-19/domains/ingestion.md`.
