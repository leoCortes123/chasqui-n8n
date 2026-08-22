---
id: ROUTER-001
dominio: router
estado: vigente
fecha: 2026-08-19
titulo: El router es un despachador delgado con un handler por estado
invariantes:
  - una migración que cambia el comportamiento de un estado reemplaza sólo el handler de ese estado
  - ninguna migración vuelve a copiar el router entero para cambiar unas líneas
  - el canal de entrada viaja en el evento normalizado, no en el nombre de la función
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: [CONTENIDO-001, MIGRACION-001]
implementada_en: [agent-context/history/migraciones/056_router_modular.sql]
afecta: [router_procesar_mensaje, router_ctx, router_h_recibiendo, usuario_de_canal]
procedencia: cabecera de la migración 056 (CAND-056), promovida el 2026-08-19
---

## Problema medido

`router_procesar_mensaje` iba por su octava copia íntegra: las migraciones 012,
015, 016, 024, 030, 033, 041, 042, 043, 045, 046, 051 y 053 pegaron las mismas
trescientas líneas para cambiar seis.

No fue un problema estético: **se perdió un fix por ese mecanismo**. El campo
`periodo` que la 046 agregó a `ingesta_resumen_sesion` con justificación
explícita lo borró la 051 sin mencionarlo, simplemente porque pegó encima una
versión anterior del bloque.

## Decisión

Un despachador delgado (`router_procesar_mensaje`) que arma el contexto
(`router_ctx`) y delega en un handler por estado: `router_h_sin_sesion`,
`router_h_intake`, `router_h_recibiendo`, `router_h_comandos`,
`router_h_admin`. Cada migración futura reemplaza el handler que le toca y deja
los otros intactos.

El canal es parte del evento, no del código: `usuario_de_canal` lo lee del
evento normalizado que arman nuestros propios workflows.

## Alternativas descartadas

- **Seguir con el router monolítico.** Cada fase que lo tocara pagaba el
  impuesto de la copia íntegra y arriesgaba repetir la regresión de la 051.
- **Un router por canal.** Ver `CONTENIDO-001`.

## Consecuencias

Un cambio de conversación se localiza en un handler. Si una migración vuelve a
redefinir `router_procesar_mensaje` completo, eso es la señal de que algo se
está haciendo en el nivel equivocado.
