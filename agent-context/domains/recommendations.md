---
id: DOMAIN-RECOMENDACIONES
type: domain
status: active
implemented_in: [db/actual/funciones/recomendaciones_*.sql, db/actual/funciones/recomendacion_*.sql, db/actual/funciones/pedido_sugerido.sql, db/actual/tablas/recomendaciones.sql]
---

# Recomendaciones (detectar → persistir → cerrar → medir)

**Propósito**: que un consejo sobreviva al informe que lo llevó, se pueda
accionar y su resultado se mida después (`CORE-003`).

| | |
|---|---|
| **Entry points** | `ejecucion_cerrar` → `recomendaciones_registrar` → `recomendaciones_medir`; botones `rec:*` → `router_h_comandos` → `recomendacion_accion` |
| **Tablas primarias** | `recomendaciones`, `metricas_resultado` (11 filas, una por regla), `alertas_enviadas` |
| **Funciones primarias** | `recomendaciones_negocio(negocio, p_registro)` · `recomendaciones_registrar` · `recomendacion_marcar_cierre` · `recomendaciones_medir` · `recomendacion_metrica_valor` · `recomendacion_objeto_evaluable` |
| **Decisiones** | `CORE-003`, `CORE-001`, `DATOS-001`, `ALERTAS-001` |

## Ciclo de vida `[CONFIRMADO]`

```text
nueva ──entró al informe──► vigente (vista_en, veces_vista++)
(→ resuelta si ya no se detecta Y objeto evaluable, cerrada_por='dato')
(→ caducada si no evaluable, 'sin_datos')
vigente ──rec:hice──► resuelta ('accion_usuario')  ──rec:no_aplica──► ignorada
cerrada+valor_al_cerrar → recomendaciones_medir → resultado positivo|neutro|negativo
```
CHECK: abierta (nueva|vigente) ⇔ `cerrada_en IS NULL`. Índice parcial único:
una sola abierta por `(negocio, regla, clave_objeto)`.

## Detectado ≠ mostrado `[CONFIRMADO]`

`p_registro=true` devuelve **todo** (lo usan registrar y alertas);
modo informe devuelve máx **2 por regla y 8 en total**. El modo informe omite
claves internas (`regla`, `clave_objeto`, `datos`) a propósito: el modelo no las
ve y `validar_cifras` no las da por buenas.

## Prioridad `[CONFIRMADO]`

Umbrales por `impacto_tipo` en filas: mensual alta=2%/media=0,5% · unico
10/3 · capital 50/20. `dependencia` entra fija media. `relevancia = pct /
umbral_media_de_su_tipo` — lo único comparable entre tipos.

## Trampas

- `metricas_resultado.regla` no tiene FK: regla nueva sin fila ⇒ nunca se mide,
  en silencio.
- Las 11 reglas viven en `recomendaciones_negocio` (683 líneas); umbrales en
  `parametros` **salvo**: 5% de R2 y los 14 días de R7 hardcodeados (DISC-C10).
- "Ejecutar" no existe sobre sistemas externos: aplicar precio escribe un hecho
  en `conocimiento`; `pedido_sugerido` es para mirar (DISC-I4).
- Proactividad independiente: `alertas_evaluar` lee el modo registro aunque no
  haya informes completados (hoy 57 alertas con 0 ejecuciones).
