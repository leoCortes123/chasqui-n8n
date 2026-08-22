---
id: CONTRACT-HALLAZGOS-PROMPT
type: contract
status: active
provider: ejecucion_preparar / hallazgos_* (SQL)
consumers: [wf_ejecutar (nodos LLM), informe_render, validar_cifras, DOMAIN-INTELIGENCIA]
---

# Hallazgos ↔ prompt ↔ informe renderizado

**Propósito**: la frontera SQL/LLM de `CORE-001`. El modelo recibe UN JSON con
todas las cifras ya calculadas y devuelve una ESTRUCTURA; SQL la renderiza y
audita. Si se rompe este contrato, el sistema entrega el informe seco.

## 1. `ejecucion_preparar` arma el paquete `[CONFIRMADO]`

- Cupo: `v_consumo_negocio`; `cupo_tokens_mes>0 AND usados>=cupo` ⇒ bloqueada.
  OJO: `cupo=0` **nunca bloquea** aquí, pero `router_plan` lo lee como
  "suspendido" (DISC-A1).
- Despacho dinámico por filas:
  `EXECUTE format('SELECT %I($1,$2)', servicios.funcion_hallazgos)` con
  `to_regprocedure('%I(bigint,jsonb)')` previo — firma obligatoria `(bigint, jsonb)`.
- Prompt activo único por servicio (`uq_prompt_activo`). Variables:
  `{{hallazgos}}` sustituida por nodo Code.

## 2. Forma del JSON de hallazgos por servicio

| Servicio | Función | Claves |
|---|---|---|
| `ventas_compras` | `hallazgos_generar` | salud(6 notas)+indice · recomendaciones[] con top 8 y textos ya redactados por SQL, sin claves internas · comparativo · periodo · resumen · margen_bajo/deriva_costo/baja_cobertura/pareto |
| `mercado_compras` | `hallazgos_compras` | periodo · resumen · gasto_producto · deriva_costo · precio_disperso · proveedores · sin_venta (**sin** recomendaciones/salud) |
| `consulta` | `contexto_negocio_recuperar` | pregunta · hechos(KB, manda sobre todo) · consulta|intención resuelta · negocio(perfil) · estado(salud) · comparativo · recomendaciones vigentes |

## 3. Respuesta esperada del modelo (`response_format json_object`)

```jsonc
// informe:
{ "titular": "≤100", "hallazgos": [{"icono","titulo","problema","impacto",
   "opciones": ["≤3"], "prioridad": "..."}], "acciones": ["≤3"] }
// consulta:
{ "titular": "≤200", "secciones": [{"icono","titulo","puntos":[]}], "acciones": [] }
```

## 4. Validación en cadena (4 filtros)

1. `Extraer` (JS): inválido si `finish_reason='length'`, JSON no parseable u objeto ausente.
2. `informe_render`: NULL si titular vacío/estructura mala; iconos contra lista blanca (10); escape HTML salvo crudas.
3. `validar_cifras(texto_renderizado, hallazgos)`: todo número ≥3 dígitos del texto debe existir en el conjunto permitido extraído de los hallazgos — con formato humano colombiano (`cifra_variantes`, coma decimal). Verifica **existencia**, no corrección (RI-14).
4. Nodo `Cifras1ok?`: ok ∧ ¬invalido ∧ texto no vacío.

Fallo ⇒ reintento único (mismo body) ⇒ informe seco
(`informe_estructura_seca` + mismo `informe_render`; entrega válida, no error).

## Precondiciones / postcondiciones

- Pre: ejecución `preparando`, prompt activo, función de hallazgos existente.
- Post (`ejecucion_cerrar`): snapshot (servicios con archivos), recomendaciones
  registradas y medidas, sesión cerrada, plantilla `ejecucion.entregada.<svc>`.

## Errores

| Fallo | Resultado |
|---|---|
| HTTP 429/timeout | `onError: continueRegularOutput` → invalido → reintento → seco |
| Cupo mensual | `bloqueada`, sin gastar tokens |
| Sin prompt o sin función | `fallida` + `ejecucion.fallida` |

## Tests

`db/pruebas/aceptacion.sql` (ciclo completo sin LLM), `empty_state.sql`
(informe que declara no tener datos), E2E `--con-llm` (manual, cuesta tokens).
