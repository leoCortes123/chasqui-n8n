---
id: DOMAIN-CONVERSACION
type: domain
status: active
depends_on: [DOMAIN-CANALES]
implemented_in: [db/actual/funciones/router_*.sql, db/actual/funciones/consulta_iniciar.sql, db/actual/funciones/intencion_*.sql, bin/gen_wf_router.py]
---

# Conversación (router, sesiones, consulta)

**Propósito**: decidir qué contesta el sistema a cada evento; sostener el estado
de la sesión; resolver preguntas en lenguaje natural sin LLM en la detección.

| | |
|---|---|
| **Entry points** | `router_procesar_mensaje(p_evento jsonb) → jsonb` — único punto, llamado por `wf_router` y `wf_wa_router` |
| **Entradas** | evento normalizado `{canal, from, chat, texto, tiene_documento, callback_id, message_id, file_id…}` (CONTRACT-EVENTO-ROUTER) |
| **Salidas** | `{chat_id, respuestas[], acciones[]}` vía `router_respuesta` (+ `editar` opcional) |
| **Tablas primarias** | `sesiones` (máquina de estados), `usuarios`, `identidades`, `intenciones`, `conocimiento(_pendiente)` |
| **Funciones primarias** | `router_ctx` · handlers: `router_h_admin` (antes de sesión), `router_h_comandos` (251 líneas), `router_h_sin_sesion`, `router_h_intake`, `router_h_recibiendo` |
| **Dependencias** | DOMAIN-INGESTA (`carga_evaluar` para `/listo`), DOMAIN-INTELIGENCIA (consulta dispara ejecución) |

**Contratos**: [`../contracts/router-evento.md`](../contracts/router-evento.md).
**Decisiones**: `ROUTER-001`, `CONTENIDO-001`, `PLANES-001`.
**Invariantes**: INV-019…INV-022.
**Tests**: `db/pruebas/router_casos.sql` (67 casos, salida normalizada comparativa,
sin golden file a propósito).

## Estados de `sesiones` `[CONFIRMADO]`

```text
intake ──elegir svc──► recibiendo ──carga_arrancar──► procesando
recibiendo ──/cancelar──► expirada        procesando ──► completada | fallida
consulta: nace 'procesando' y muere con su ejecución
expiración automática: 24 h (mantenimiento_ciclo)
```

## Reglas del despacho que no se ven a simple vista

1. `router_h_admin` corre **antes** de tocar la sesión (`/salud` no refresca actividad).
2. Consentimiento es puerta dura: hasta `autorizacion_datos`, todo lo no
   informativo responde `sistema.consentimiento`. Al aceptar
   (`acepto:<texto original>`) el router se re-invoca con el texto original.
3. Con sesión `procesando`: documento ⇒ acción `ingerir` igual (INV-009);
   sin documento ⇒ `ejecucion.ya_en_curso`.
4. Botones son comandos: prefijos `svc:` `mod:` `modayuda:` `tipo:` `rec:` `acepto:`.
5. Plantillas con `reemplaza=true` (14 hoy) se **editan** en lugar de enviarse
   nuevas si el evento fue un callback (`router_marcar_editables`).
6. Consulta en texto libre entra por `router_h_sin_sesion` al final: intención
   **léxica** (`intenciones.patrones` + LIKE), periodo "hoy" = `max(fecha)` de
   movimientos, no `current_date`.

## Lo que un agente suele romper

- Redefinir `router_procesar_mensaje` completo en una migración: señal de nivel
  equivocado (ROUTER-001). Cambiar sólo el handler del estado.
- Romper el contrato del evento normalizado (los dos routers arman lo mismo).
- Asumir memoria conversacional: no existe; cada pregunta se resuelve sola.
- Mover el menú detrás del consentimiento (INV-021).
