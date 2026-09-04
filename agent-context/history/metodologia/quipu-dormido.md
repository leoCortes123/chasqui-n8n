# La §Quipu que afirmaba que Quipu no tenía mitad normativa (2026-08-22 → 2026-08-28)

**Documento archivado.** Se conserva porque era **falso**, y saber en qué se
equivocó evita repetir el error: se describió a Quipu leyendo la lista de tools
que respondía la instancia de ese día, no su código fuente.

Vigente hoy: `AGENTS.md` §Quipu y `decisiones/PROCESO-002.md`.

---

## Lo que decía `AGENTS.md` (líneas 104-144, versión del 2026-08-22)

> Quipu es una app aparte (Laravel en `localhost:8001`) que traza el trabajo pieza
> a pieza: bloque → microtarea → evidencia → gate. **Está a medio construir.**
>
> **En operación — el flujo de demanda.** Herramientas del MCP `quipu`:
> `get_ready_blocks`, `get_block_detail`, `claim_block`, `get_my_tasks`,
> `declare_deliverables`, `plan_microtasks`, `start_microtask`, `add_evidence`,
> `link_criteria`, `mark_criterion_met`, `get_gate_status`, `complete_task`,
> `get_feature_design`, `get_endpoint_schema`, `get_screen_design`.
>
> **No existe — la mitad normativa.** No se invoca ni se planifica con nada de
> esto: tools `dominio_contexto`, `decision_leer`, `invariantes_de`,
> `verificar_contradicciones`, `decision_proponer`, `registrar_contradiccion`
> como tools de Quipu; el endpoint REST de promoción de decisiones
> (`decision:aprobar`); las tablas `dominio`, `decision`, `decision_supersede`,
> `invariante`, `contradiccion` y sus gates.
>
> **Hoy Quipu no tiene ningún bloque de Chasqui cargado** (`get_ready_blocks` → 0).
> Mientras siga así, el desarrollo avanza por `pedidos/` exactamente como hasta
> ahora.

## En qué se equivocaba

Verificado el 2026-08-28 contra `QUIPU_ENTERPRISE/code/api`:

| Afirmación archivada | Realidad medida |
|---|---|
| «15 tools, sólo flujo de demanda» | `QuipuServer.php` registra **41 tools en cuatro capas** |
| «no existe la mitad normativa» | existe como **cadena de gobierno**: `necesidad → cambio → requisito → cobertura`, con `registrar_necesidad`, `triar_necesidad`, `crear_cambio`, `declarar_requisitos`, `enlazar_cobertura`, `get_cambio_gate_status`, y **seis puertas de cierre** |
| «no hay tablas de norma» | hay `necesidad`, `cambio`, `requisito`, `requisito_criterio`, `enlace`, `firma`, `politica_autorizacion`, y triggers de segregación de funciones |
| «Quipu no congela trabajo que contradiga algo ya decidido» | **cierto, y sigue siéndolo** — pero por otra razón: `business_rule` no tiene ciclo de vida y `block_rule` está muerta. Ver `PROCESO-002` |
| «0 bloques cargados» | 8 bloques (P-002…P-009), 43 rules, 8 features, 32 endpoints, 2 pantallas, 8 lecciones |

## La lección

Lo que se nombra distinto se da por inexistente. Quipu no usa las palabras de
Chasqui —«decisión» es `cambio` + `requisito`, «invariante» es `business_rule`,
«contradicción» es `enlace sospechoso`— y la descripción se escribió buscando los
nombres de Chasqui en la lista de tools. La mitad de Quipu quedó invisible cinco
días.

Está registrada en la knowledge base de Quipu; el equivalente en este repositorio
es esta página.
