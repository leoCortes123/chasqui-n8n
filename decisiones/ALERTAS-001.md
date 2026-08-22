---
id: ALERTAS-001
dominio: alertas
estado: vigente
fecha: 2026-08-19
titulo: Chasqui habla primero, pero un bot que avisa de más lo silencian
invariantes:
  - sólo se avisa prioridad alta; lo demás espera al informe
  - un aviso por negocio por corrida, nunca una ráfaga
  - el mismo problema no se avisa dos veces dentro del cooldown, aunque siga estando
  - no se avisa fuera de la franja horaria del negocio ni sin datos nuevos desde el último análisis
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: [CORE-003, INFORME-001]
implementada_en: [agent-context/history/migraciones/067_alertas.sql]
afecta: [mantenimiento_ciclo, alertas_enviadas, recomendaciones_negocio]
procedencia: cabecera de la migración 067 (CAND-067), promovida el 2026-08-19
---

## Problema medido

Todo lo que hacía el sistema empezaba porque el dueño escribía algo. Si subía
las ventas de la semana y no tocaba "Analizar", nadie le decía que un producto
se estaba agotando — aunque el dato ya estuviera cargado y la regla ya lo
supiera. El valor estaba calculado y no llegaba.

## Decisión

Chasqui inicia la conversación, y todo el diseño se ordena alrededor de no
gastar ese permiso:

- Sólo prioridad **alta**. Lo demás espera al informe.
- **Un** aviso por negocio por corrida.
- **Cooldown** por regla + objeto: el mismo problema no vuelve dentro de
  `alerta_cooldown_dias`, aunque siga vigente.
- **Franja horaria** del negocio. Un aviso a las 3 de la mañana es la forma más
  rápida de que lo bloqueen.
- Sólo si **entraron datos nuevos** desde el último análisis: sin datos nuevos no
  hay nada que el dueño no haya visto ya.

Los cinco límites son parámetros, no constantes en el código.

## Alternativas descartadas

- **Avisar todo lo que las reglas detecten.** Es la ráfaga; y un bot silenciado
  no sirve para nada, con lo cual se pierde también lo que sí importaba.
- **Dejar que el modelo decida qué amerita aviso.** La prioridad sale de reglas
  con umbrales en filas (`CORE-001`), no de un juicio irreproducible.

## Consecuencias

Un problema real puede tardar en avisarse, o no avisarse nunca si nunca alcanza
prioridad alta. Es deliberado: el canal de aviso proactivo se protege a costa de
la exhaustividad, y lo exhaustivo es el informe.
