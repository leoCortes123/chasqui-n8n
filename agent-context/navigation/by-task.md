---
id: NAV-BY-TASK
type: navigation
status: active
---

# Navegación por tarea

Sólo tareas que existen en este proyecto. Cada ruta termina en código canónico
y verificación. Regla general previa: `AGENTS.md` §protocolo.

**Antes de la primera línea de cualquiera de estas tareas**: el cambio se escribe
en `pedidos/NNN-slug.md` (skill `/pedido`) y espera aprobación. Un pedido en
`propuesto` no autoriza nada (`PROCESO-001`, `pedidos/README.md`). Las rutas de
abajo son el contenido del pedido, no un permiso para saltárselo.

## 1. Cambiar un texto, botón, umbral o prompt (contenido)

1. [../invariants/INVARIANTES.md](../invariants/INVARIANTES.md) INV-007, INV-024.
2. Localiza la fila: `db/actual/contenido/{plantillas,prompts,parametros,servicios,...}.sql`.
3. El cambio es **migración** (`db/migraciones/077_...`, cabecera con porqué) +
   `bash bin/gen_estado_sql.sh`. Nunca editar el workflow ni `db/base/`.
4. Verificar: `bash bin/verificar.sh --rapido` + banco del dominio tocado.
   Si tocas teclado: regenerar `bin/gen_wf_enviar.py` si cambia nº de filas (DISC-D3).

## 2. Agregar un servicio de análisis

1. [../invariants/INVARIANTES.md](../invariants/INVARIANTES.md) INV-006, INV-008.
2. Modelo a copiar: filas en `servicios`, `servicios_entradas`, `prompts`
   (contrato de salida: [../contracts/hallazgos-prompt.md](../contracts/hallazgos-prompt.md)).
3. Escribir su función de hallazgos con firma EXACTA `(bigint, jsonb)`
   ([MIGRACION-001] — DROP de firmas viejas si aplica).
4. Despacho automático vía `servicios.funcion_hallazgos`; n8n intacto.
5. Verificar: E2E `python3 bin/prueba_ciclo_vida.py`; `verificar.sh` chequeo 9.

## 3. Modificar la ingesta o soportar un formato nuevo

1. [../domains/ingestion.md](../domains/ingestion.md) +
   [../contracts/mapeo-ingesta.md](../contracts/mapeo-ingesta.md) + INV-009..012.
2. Código: `ingesta_identificar_tabular`, `sinonimos_columna` (diccionario),
   compuerta en `ingesta_cargar_tabular_detalle`.
3. Formato fijo a mano = fila en `formatos_documento` (origen semilla).
   Aprendidos no entran al baseline (BASE-001, chequeo 8).
4. Tests: `bash bin/pruebas.sh ingesta_sin_modelo carga_sin_perdida`.

## 4. Modificar una regla o umbral de recomendaciones

1. [../domains/recommendations.md](../domains/recommendations.md) + INV-001.
2. Reglas: `recomendaciones_negocio.sql` (R1..R11). Umbrales: filas de
   `parametros` (¡excepciones hardcodeadas R2/R7! DISC-C10).
3. Regla nueva ⇒ fila en `metricas_resultado` o nunca se medirá (silencioso).
4. Tests: `bash bin/pruebas.sh reglas_comparativas aceptacion`.

## 5. Cambiar el flujo de conversación

1. [../domains/conversation.md](../domains/conversation.md) + INV-018..021 +
   [../contracts/router-evento.md](../contracts/router-evento.md).
2. Cambia SOLO el handler del estado (`router_h_*`) en una migración.
   Redefinir el router entero es violación de ROUTER-001.
3. Textos/botones nuevos: migración de `plantillas` (+`reemplaza` si es navegación).
4. Tests: `db/pruebas/router_casos.sql` (comparar salida normalizada antes/después).

## 6. Exponer una función nueva al portal

1. [../contracts/rpc-portal.md](../contracts/rpc-portal.md) + INV-017.
2. Checklist obligatorio: sin `negocio_id` param · `GRANT EXECUTE` explícito ·
   `NOTIFY pgrst` al final de la migración · devuelve jsonb ·
   `WHERE negocio_id = portal_negocio()` dentro.
3. Verificar permisos contra catálogo como en `agent-context/reference/seguridad.md §2`.

## 7. Tocar un workflow de n8n

1. INV-025: los JSON son generados. Edita `bin/gen_wf_<x>.py` y regenera
   (`python3 bin/gen_wf_<x>.py`), importa y publica:
   `bash bin/importar-workflows.sh`.
2. Antes, lee las restricciones reales del nodo Telegram (teclado literal,
   parse_mode HTML): [../domains/channels.md](../domains/channels.md).
3. Verificar: `bash bin/verificar.sh --rapido` (chequeo 1 reproduce byte a byte).

## 8. Escribir una migración

1. INV-023, INV-026; numeración siguiente: hoy **077**
   (`ls db/migraciones/` para confirmar).
2. Cabecera ≥5 líneas de prosa (problema medido → reglas → alternativas).
   Cambio de firma ⇒ DROP en la misma migración. RPC ⇒ NOTIFY pgrst final.
3. Después: `bash bin/migrar.sh` + `bash bin/gen_estado_sql.sh`.

## 9. Depurar un fallo observado

1. `fallas` (via `admin_reporte`: `/fallas /salud /embudo /consumo /matching`
   como admin) y vistas `v_ejecuciones_fallidas`, `v_sesiones_atascadas`,
   `v_salud_ingesta`, `v_calidad_matching`.
2. Errores de n8n sólo sobreviven 7 días y éxitos no se guardan (RI-9):
   la evidencia viva está en Postgres, no en n8n.
3. Contexto histórico del incidente actual: `agent-context/history/auditorias/2026-08-19/orden-de-trabajo.md` (A-01..A-13).

## 10. Dejar la base limpia para probar

`bash bin/limpiar_negocio.sh` y nada más (no preguntar alcance, no respaldos;
si la base está ocupada, esperar). Detalle normativo: AGENTS.md §limpiar.

## 11. Verificar tus cambios y cerrar el pedido (cierre de toda tarea)

```bash
bash bin/verificar.sh --rapido        # estructura (chequeo 2 REGENERA db/actual/)
bash bin/pruebas.sh                   # bancos SQL, todo ROLLBACK
python3 bin/prueba_ciclo_vida.py      # E2E sin LLM (--con-llm cuesta tokens)
```
No modificar tests para que pasen; discrepancias de contrato de prueba se
registran (ejemplos vivos: DISC-T1/T2).
