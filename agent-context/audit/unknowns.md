---
id: AUDIT-UNKNOWNS
type: audit
status: active
---

# Desconocidos

Preguntas que NO pueden resolverse inspeccionando el repositorio. No se rellenan
con suposiciones. Los diez primeros ítems están desarrollados con evidencia
inspeccionada en `../../agent-context/history/auditorias/2026-08-19/unknowns-and-discrepancies.md` §7 (ND-1…ND-10).

| id | Pregunta | Por qué el repo no alcanza |
|---|---|---|
| UNK-1 | ¿Se completó alguna vez un análisis en esta instalación? | `ejecuciones` vacía y n8n no guarda éxitos (`SAVE_ON_SUCCESS=none`) |
| UNK-2 | ¿Por qué Telegram devuelve `Forbidden`? | `fallas` guarda mensaje, no cuerpo; requiere consultar la API (causa candidata A-12: bot bloqueado tras la ráfaga A-10) |
| UNK-3 | ¿Cuánto tarda `wf_ejecutar` punta a punta? | nunca se completó una ejecución; sólo hay mediciones SQL aisladas |
| UNK-4 | ¿El informe narrado pasa `validar_cifras` con el modelo actual? | exige gastar tokens (`prueba_ciclo_vida.py --con-llm`, no corrido) |
| UNK-5 | ¿Los workflows desplegados son idénticos nodo a nodo al repo? | se comparó nº de nodos + reproducibilidad del JSON; no diff del desplegado |
| UNK-6 | ¿Funciona el portal de punta a punta? | requiere token vivo y navegador |
| UNK-7 | ¿Qué produce WhatsApp con credenciales reales? | sin credenciales de Meta |
| UNK-8 | ¿Por qué `datos_incompletos` no dispara `agota` ni `cartera`? | deuda D-009 abierta: no se sabe qué lado miente |
| UNK-9 | ¿Cuál es la intención con `cupo_tokens_mes=0`? | dos lecturas incompatibles en código, ninguna decisión escrita (DISC-A1) |
| UNK-10 | ¿La huella colisiona en la práctica con formatos distintos? | diseño lo permite (columnas iguales ⇒ misma huella); sin caso observado |

## Nuevos de esta auditoría

```text
UNK-N1
Question: [RESUELTO 2026-08-22 — DOCS-001: el árbol se archivó en agent-context/history/auditorias/2026-08-19/ y esta capa es la única descriptiva] ¿Quién o qué generó el árbol docs/ de auditoría (architecture/, domains/,
          interfaces/…, 2026-08-19) y cómo se regenera o actualiza?
Evidence inspected:
  - bin/: ningún script generaba docs/architecture|domains|interfaces.
  - git status: todo el árbol está sin trackear (DISC-N1).
  - agent-context/history/auditorias/2026-08-19/README.md: declara proveniencia "auditoría de ingeniería inversa"
    hecha contra código y catálogo vivo, sin nombrar herramienta.
Conclusion: La motivación existe (auditoría), el mecanismo de generación no está
registrado. Estado CONFIRMED de que no hay generador; UNKNOWN el proceso.
```

```text
UNK-N2
Question: ¿Los fixtures DIAN sintéticos validan contra XML real de cliente?
Evidence inspected: README §riesgo abierto lo declara; ejemplos/dian_oficiales/
  trae 13 XML del set oficial DIAN; no hay evidencia de contraste con facturas reales.
Conclusion: Riesgo declarado, no resuelto desde el repositorio.
```
