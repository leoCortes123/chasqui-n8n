---
id: AUDIT-DISCREPANCIES
type: audit
status: active
---

# Discrepancias registradas (no corregidas)

Registro, no plan de acción. Fuentes previas que esto **referencia y no repite**:
`decisiones/deuda.md` (D-001…D-010, deuda deliberada) y
`agent-context/history/auditorias/2026-08-19/orden-de-trabajo.md` (A-01…A-13, orden de trabajo del incidente).
Los ids `DISC-*` de acá son los que usan el resto de `agent-context/`.
Detalle completo de cada ítem: `../../agent-context/history/auditorias/2026-08-19/unknowns-and-discrepancies.md`
(secciones 1–6, misma numeración).

## Contradicciones documentación vs código

| id | Resumen | Verificado |
|---|---|---|
| DISC-C1 | ~~README cita `teclado_servicios()`: no existe~~ — **corregido el 2026-08-22**: dice `teclado_intake()` | ✅ por esta auditoría (`ls db/actual/funciones \| grep teclado`) |
| DISC-C2 | README "Los 7 workflows" lista 6; falta `wf_wa_router` | ✅ conteo propio |
| DISC-C3 | README: "próxima migración 075"; ya aplicadas 075 y 076 | ✅ `ls db/migraciones` |
| DISC-C4 | ~~README declara 34 parámetros; hay 35~~ — **corregido el 2026-08-22** | auditoría 2026-08-19 |
| DISC-C5 | GUIA_TECNICA no conoce el panel de carga (071–076): describe modelo anterior | auditoría 2026-08-19 |
| DISC-C6 | TELEGRAM_UX lista como futuro algo ya implementado (070) | auditoría 2026-08-19 |
| DISC-C8 | AGENTS congela "cotizador"; está implementado punta a punta ("congelado" = no invertir más) | auditoría 2026-08-19 |
| DISC-C9 | Tesis "sin lógica de negocio en nodos": excepciones vivas (troceo 3800, delimitador CSV, muestras 5/100, espera 11s, MAX_FILAS, regex transitorio, INSERT literal) | ✅ generadores |
| DISC-C10 | CONTENIDO-001 "umbral=fila": `match_umbral_trgm` sin fila (coalesce 0,45); 5% de R2 y 14 días de R7 hardcodeados | auditoría 2026-08-19 |
| DISC-C11 | HALLAZGOS-001: liquidez promedia pero `informe_salud_bloque` sólo pinta 5 notas; plantilla `informe.salud_etiqueta.liquidez` sin lector | auditoría 2026-08-19 |
| DISC-C12 | README describe `mantenimiento_ciclo` incompleto (son 4 pasos) | auditoría 2026-08-19 |

## Implementación incompleta / infraestructura sin flujo

| id | Resumen |
|---|---|
| DISC-I1 | WhatsApp completo en código, credenciales vacías ⇒ URLs sin id y filtro saltado |
| DISC-I2 | Switch de WhatsApp sin salida `panel` ⇒ descarte silencioso |
| DISC-I3 | WhatsApp esperaría a wf_ejecutar y reenviaría el informe ya entregado |
| DISC-I4 | "Ejecutar" acción externa no existe: registrar y medir, no actuar |
| DISC-I5 | `ingesta_cargar_inventario` inalcanzable desde chat; conteos sólo por portal |
| DISC-I6 | `ejecuciones.costo` nunca se escribe; `costo_por_1k_tokens_usd` sin lector |
| DISC-I7 | `narrado` no se persiste: imposible saber cuántos informes salieron secos |
| DISC-I8 | `cuadra` (factura DIAN cuadrada) se calcula y nadie la consume |
| DISC-I9 | `negocios.nit` NULL ⇒ todo entra como compra; sin liquidez ni regla cartera |
| DISC-I10 | `snapshots_backfill` sin llamador (deuda D-006) |
| DISC-I11 | Sin usuario admin en esta instalación: fallas no avisan a nadie |
| DISC-I12 | `parametros.pago_enlace` sin filas: código de cobro sin dato |

## Duplicaciones

| id | Resumen |
|---|---|
| DISC-D1 | Dos modelos de identidad (`usuarios.telegram_*` vs `identidades`); vistas de alerta leen sólo el viejo |
| DISC-D2 | Dos identidades de proveedor (texto libre vs `terceros`) sin conciliar |
| DISC-D3 | Tope de teclado en dos sitios (`parametros` y `MAX_FILAS` del generador) |
| DISC-D4 | `origen='inferido'` para formato aprendido con y sin modelo |
| DISC-D5 | Dos relojes de "hoy" (`max(fecha)` vs `current_date`) conviviendo |
| DISC-D6 | Sobrecargas `(bigint,jsonb)` deliberadas — NO es defecto (MIGRACION-001) |

## Ambigüedades sin decisión escrita

| id | Resumen |
|---|---|
| DISC-A1 | `cupo_tokens_mes=0`: nunca bloquea (preparar) vs "suspendido" (router_plan) |
| DISC-A2 | `db/actual/contenido/` mezcla producto con lo aprendido de un cliente (A-13) |
| DISC-A3 | Nombre del modelo: entorno vs fila de producto (deuda D-007) |
| DISC-A4 | "Tengo con qué" tiene dos semánticas según servicio (`carga_hay_con_que`) |
| DISC-A5 | `ejecucion_cerrar` registra recomendaciones de ventas también para `mercado_compras`, cuyo informe no las muestra |
| DISC-A6 | Prompt de `mercado_compras` describe un producto distinto del que entrega |

## Tests con contrato viejo (no corregir el test a ciegas)

| id | Banco | Esperado→Obtenido | Causa |
|---|---|---|---|
| DISC-T1 | carga_sin_perdida `silencio sin botón → panel` | panel→nada | guardarraíl "panel en vuelo" de la 075 |
| DISC-T2 | ingesta_sin_modelo agregado | error→descartado | la 075 separó descarte de error |

## Hallazgos nuevos de esta auditoría

| id | Resumen |
|---|---|
| DISC-N1 | ~~El árbol `docs/` de auditoría inversa está sin trackear y puede derivar sin rastro~~ — **resuelto el 2026-08-22** (`DOCS-001`): lo vivo se absorbió en esta capa, lo duplicado quedó en `agent-context/history/auditorias/2026-08-19/` |
| DISC-N2 | `AGENTS.md` §configuración declara el modelo horneado correcto hoy, pero el DEFAULT de columna sigue apuntando a un modelo inexistente en el proxy (ver deuda D-007): un INSERT de prompt sin `modelo` nace roto |

## Riesgos de interpretación (trampas para agentes)

Lista completa RI-1…RI-16 en `../../agent-context/history/auditorias/2026-08-19/unknowns-and-discrepancies.md` §6.
Las más caras: RI-1 (leer migraciones/histórico para saber cómo funciona),
RI-2/RI-3 (editar JSON o leer fotos), RI-4 (`movimientos` vs `mov_visibles`),
RI-9 (éxitos sin rastro en n8n), RI-13 (verificar.sh escribe), RI-16 (baseline
congelado ≠ esquema actual).
