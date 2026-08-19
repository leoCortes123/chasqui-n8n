---
id: CAND-067
dominio: alertas
estado: candidato
titulo: 067_alertas.sql — Chasqui habla primero
invariantes: []          # llenar a mano al promover
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: []
implementada_en: [docs/historico/migraciones/067_alertas.sql]
afecta:
  - IF   # ya no existe en db/actual/
  - alertas_evaluar
  - mantenimiento_ciclo
  - v_negocios_alertables   # ya no existe en db/actual/
procedencia: cabecera de docs/historico/migraciones/067_alertas.sql, commit e606c05 2026-08-15
---

> **Candidato, no decisión.** Extraído automáticamente el 2026-08-18.
> Nada de acá gobierna hasta que se revise, se le fije estado y se
> mueva a `decisiones/`.

## Reglas enunciadas en la cabecera

### LA REGLA QUE GOBIERNA ESTA MIGRACIÓN

**Un bot que avisa de más lo silencian, y silenciado no sirve para nada.**
Todo lo de acá está diseñado alrededor de eso, no alrededor de avisar:

* Solo prioridad **alta**. Lo demás espera al informe.
* **Un** aviso por negocio por corrida. Nunca una ráfaga.
* **Cooldown** por regla+objeto: el mismo problema no se avisa dos veces en
dos semanas, aunque siga estando.
* **Horario**: nada fuera de la franja del negocio. Un aviso a las 3 de la
mañana es la forma más rápida de que lo bloqueen.
* Solo si **entraron datos nuevos** desde el último análisis. Sin datos
nuevos no hay nada que el dueño no haya visto ya.

## Cabecera completa, textual

```
067_alertas.sql — Chasqui habla primero.

Hasta acá todo lo que hace el sistema empieza porque el dueño escribió algo.
Sube archivos, pide el análisis, pregunta. Si sube las ventas de la semana y
no toca "Analizar", nadie le dice que un producto se le está agotando — aunque
el dato ya esté cargado y la regla ya lo sepa.

LA REGLA QUE GOBIERNA ESTA MIGRACIÓN

**Un bot que avisa de más lo silencian, y silenciado no sirve para nada.**
Todo lo de acá está diseñado alrededor de eso, no alrededor de avisar:

* Solo prioridad **alta**. Lo demás espera al informe.
* **Un** aviso por negocio por corrida. Nunca una ráfaga.
* **Cooldown** por regla+objeto: el mismo problema no se avisa dos veces en
dos semanas, aunque siga estando.
* **Horario**: nada fuera de la franja del negocio. Un aviso a las 3 de la
mañana es la forma más rápida de que lo bloqueen.
* Solo si **entraron datos nuevos** desde el último análisis. Sin datos
nuevos no hay nada que el dueño no haya visto ya.

LO QUE EL AVISO HACE, Y LO QUE NO

Avisa y ofrece el análisis. **No** registra la recomendación ni la marca como
vista: eso lo hace `recomendaciones_registrar` cuando hay un informe de
verdad (B2), y meter mano acá haría que `veces_vista` contara mensajes que no
son informes. El aviso lleva un hallazgo real —calculado con la misma función
que el informe— y un botón para ver todo.

CERO NODOS NUEVOS. `wf_cron` ya corre cada 5 minutos y ya hace fanout a
`wf_enviar`; `mantenimiento_ciclo` concatena estas notificaciones a las suyas.
El contrato de salida es el mismo desde la 016: `{chat_id, respuestas[]}`.

=============================================================================
1. La memoria de lo avisado
=============================================================================
Sin esta tabla no hay cooldown, y sin cooldown Chasqui repite el mismo aviso
cada cinco minutos. Es la pieza que hace que la proactividad sea usable.
```
