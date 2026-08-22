---
id: AUDIT-COVERAGE
type: audit
status: active
---

# Cobertura de esta capa

Foto del 2026-08-21. Validación corrida: 66 enlaces internos sin rotos;
`bash bin/verificar.sh --rapido` sin violaciones (chequeos 1–6 y 8–9 OK,
bancos omitidos por `--rapido`).

| Dimensión | Cantidad | Dónde |
|---|---|---|
| Dominios documentados | 7 (+4 menores absorbidos) | `domains/` |
| Componentes mapeados | 7 workflows · 13 familias SQL · 5 de infraestructura | `navigation/by-component.md`, `architecture/components.md` |
| Contratos documentados | 5 | `contracts/` |
| Invariantes identificados | 30, con evidencia y verificación | `invariants/INVARIANTES.md` |
| Decisiones referenciadas | 20 vigentes (0 duplicadas; ids originales) | `decisiones/` vía todos los mapas |
| Diagramas | 4 estructura + 2 secuencias (espejo .md manda) | `architecture/diagrams/` |
| Índices generados | 4 JSON por `bin/gen_agent_context.py` | `generated/` |
| Desconocidos registrados | 12 (ND-1..10 + UNK-N1/N2) | `audit/unknowns.md` |
| Discrepancias registradas | ~40 ítems DISC-* + punteros a deuda D-001..010 y A-01..A-13 | `audit/discrepancies.md` |

## Reutilizado (verificado, no copiado a ciegas)

- `decisiones/*.md`: normativo completo — referenciado, nunca parafraseado como fuente.
- Auditoría inversa previa en `docs/` (2026-08-19; hoy en `agent-context/history/auditorias/2026-08-19/`): afirmaciones
  `[CONFIRMADO]` reutilizadas tras spot-check propio (teclado_servicios ausente ✅,
  conteo de nodos de los 7 workflows ✅, migraciones 074–076 ✅, 160 funciones ✅,
  203 filas de contenido ✅, grafo.json consistente ✅).
- `agent-context/reference/pruebas.md`, `agent-context/reference/seguridad.md`, `agent-context/interfaces/*`, `agent-context/reference/memoria-y-estado.md`,
  `agent-context/reference/reglas-de-negocio.md`, `agent-context/reference/modelo-de-datos.md`: referenciados como detalle
  extenso desde los mapas.

## Descubierto directo del código en esta auditoría

- Estructura completa de `db/actual/grafo.json` y su uso como base de
  `generated/symbols.json` / `dependencies.json`.
- Conteo y forma real de los 7 `wf_*.json` (nodos, errorWorkflow, sub-workflows).
- Ausencia de `teclado_servicios`; presencia de 160 funciones; estado de
  `db/migraciones` (074–076); formato del MANIFIESTO.
- El árbol `docs/` de auditoría no tenía generador ni estaba commiteado (DISC-N1/UNK-N1, resueltos el 2026-08-22 por `DOCS-001`).

## Zonas con baja confianza (no documentar como hecho)

1. Comportamiento real de WhatsApp con credenciales (UNK-7) — todo lo publicado
   sobre su salida es lectura estática del generador.
2. Tiempos punta a punta de `wf_ejecutar` (UNK-3) — cifras existentes son SQL aislado.
3. Diferencia repo↔desplegado nodo a nodo (UNK-5).
4. Estado vivo de la base (negocios, ejecuciones, fallas): esta capa documenta el
   repositorio; el estado de la instalación cambia y vive en Postgres
   (`agent-context/history/auditorias/2026-08-19/architecture/context.md` §estado observado tiene la foto del 2026-08-19).
5. Enums: única definición disponible está congelada en v0 (D-010).

## Qué NO cubre esta capa

- Ejecución de pruebas (se describen; se corren con `bin/pruebas.sh`,
  `bin/prueba_ciclo_vida.py`).
- Estado mutable de la instalación.
- Sustituir ninguna decisión: si `agent-context/` discrepa de `decisiones/`
  o de `db/actual/`, mandan ellos (regla en [`../README.md`](../README.md)).
