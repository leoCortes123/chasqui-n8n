---
id: CAND-056
dominio: router
estado: candidato
titulo: 056_router_modular.sql — se acaban las copias de 300 líneas
invariantes: []          # llenar a mano al promover
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: []
implementada_en: [docs/historico/migraciones/056_router_modular.sql]
afecta:
  - router_ctx
  - router_h_admin
  - router_h_comandos
  - router_h_intake
  - router_h_recibiendo
  - router_h_sin_sesion
  - router_procesar_mensaje
procedencia: cabecera de docs/historico/migraciones/056_router_modular.sql, commit da93a23 2026-08-15
---

> **Candidato, no decisión.** Extraído automáticamente el 2026-08-18.
> Nada de acá gobierna hasta que se revise, se le fije estado y se
> mueva a `decisiones/`.

## Cabecera completa, textual

```
056_router_modular.sql — se acaban las copias de 300 líneas.

EL PROBLEMA (H5). `router_procesar_mensaje` va por su OCTAVA copia íntegra:
012, 015, 016, 024, 030, 033, 041, 042, 043, 045, 046, 051, 053. Cada vez que
una migración necesitaba cambiar seis líneas del router, tenía que pegar las
otras trescientas. No es un problema estético: **ya se perdió un fix por ese
mecanismo**. El `periodo` que la 046 agregó a `ingesta_resumen_sesion` con
justificación explícita lo borró la 051 sin mencionarlo, simplemente porque
pegó una versión anterior encima.

Todas las fases que vienen tocan el router: C1 (preguntar a los números),
D1 (botones sobre la recomendación), F2. Con el router monolítico, cada una
paga el impuesto de la copia íntegra y arriesga repetir esa regresión.

LA FORMA. Un despachador delgado y handlers por estado. Cada migración futura
reemplaza UN handler —el que le toca— y las otras tres quedan intactas en la
base, sin que nadie tenga que volver a escribirlas.

router_ctx           parseo del mensaje + identidad + capacidades del sistema
router_h_admin       los reportes de admin
router_h_comandos    comandos y botones que no dependen del estado
router_h_sin_sesion  no hay conversación abierta
router_h_intake      hay sesión, falta elegir servicio
router_h_recibiendo  hay servicio, entran archivos

EL CONTRATO, que es lo único nuevo que hay que aprender:

* Todos los handlers reciben **un solo argumento**, `p_ctx jsonb`, con todo
ya resuelto. Se eligió jsonb sobre quince parámetros posicionales por una
razón concreta: agregarle un dato al contexto (un canal, un flag, un
estado nuevo) NO cambia ninguna firma, así que no obliga a un DROP en
cascada ni a repuntar los handlers que no se enteraron. Es el mismo patrón
de `servicios.funcion_hallazgos` y de `plantillas`: el contrato es un dato,
no una signatura.

* Un handler devuelve **NULL** para decir "esto no me toca, seguí". Es
seguro: `router_respuesta` construye siempre un objeto, nunca NULL, ni
siquiera cuando la respuesta no lleva texto (el caso `ingerir`, que
devuelve solo acciones). O sea que NULL no puede confundirse con una
respuesta legítima.

QUÉ NO CAMBIA: el comportamiento. Ni una rama nueva, ni una plantilla nueva,
ni un orden distinto. Los cuerpos de cada rama se mudaron literalmente desde
la 053. En particular se conserva un detalle fácil de perder al reordenar:
**el bloque de admin corre ANTES de leer la sesión**, y por eso un `/salud`
no le refresca `ultima_actividad` a una sesión que estaba por expirar. Por eso
`router_h_admin` es un handler aparte y no una rama más de `router_h_comandos`
(el roadmap listaba cuatro handlers; son cinco por esto).

Tampoco cambia nada en n8n: `wf_router` y `wf_wa_router` siguen haciendo una
sola llamada a `router_procesar_mensaje(evento)`, que sigue existiendo con la
misma firma y el mismo contrato de salida.

=============================================================================
1. El contexto: todo lo que el router necesita saber antes de decidir
=============================================================================
Se arma una sola vez por mensaje. No incluye la sesión a propósito: la sesión
se lee después del handler de admin (ver arriba) y el despachador la agrega
con `||`.
```
