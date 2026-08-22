---
id: CAND-071
dominio: ingesta
estado: candidato
titulo: 071_carga_sin_perdida.sql — ningún archivo que el usuario mande se pierde,
invariantes: []          # llenar a mano al promover
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: []
implementada_en: [agent-context/history/migraciones/071_carga_sin_perdida.sql]
afecta:
  - carga_arrancar
  - carga_evaluar
  - carga_hay_con_que
  - carga_panel
  - carga_panel_registrar
  - carga_registrar_fallo
  - carga_resumen
  - router_h_recibiendo
  - router_procesar_mensaje
procedencia: cabecera de agent-context/history/migraciones/071_carga_sin_perdida.sql, commit sin commit (migración aún no versionada)
---

> **Candidato, no decisión.** Extraído automáticamente el 2026-08-18.
> Nada de acá gobierna hasta que se revise, se le fije estado y se
> mueva a `decisiones/`.

## Reglas enunciadas en la cabecera

### LAS TRES REGLAS QUE SALEN DE AHÍ

1. Un archivo que llega SIEMPRE se guarda. No hay estado de la conversación
en el que un documento se conteste y se tire. Pedirle al usuario que
vuelva a buscar 60 archivos entre sus carpetas es perderlo como usuario.
2. Analizar no arranca mientras estén llegando archivos. El botón no dispara:
agenda. La corrida empieza cuando pasaron `carga_silencio_segundos` sin que
entre nada nuevo.
3. La carga entera se cuenta en UN mensaje que se edita en su lugar, no en un
mensaje por archivo. Un chat con 101 confirmaciones iguales produce la
misma desconfianza que el error que estamos arreglando.

POR QUÉ EL PANEL Y NO LA PREGUNTA "¿SON TODOS?"

La 042 ya había sacado el mensaje por archivo y lo había reemplazado por un
debounce que pregunta "¿son todos?" cuando el usuario deja de mandar. Eso
resolvía la metralleta pero no la certificación: la pregunta no dice CUÁNTO
entró, así que el usuario no tiene con qué comparar contra lo que mandó. El
panel es la misma idea llevada hasta el final: un solo mensaje, siempre el
mismo, que dice cuántos archivos y cuántos movimientos van, y que trae el
botón. La 049 puso ese botón en el mensaje de "mandame los archivos" porque no
había mejor lugar; ahora sí lo hay, y encima se fija (`pinChatMessage`) para
que el usuario no tenga que volver a buscarlo.

El debounce de wf_ingesta no se toca en su forma: sigue siendo esperar y
preguntar "¿sigo siendo el último?". Lo que cambia es a quién le pregunta —
ahora a `carga_evaluar`, que decide entre callarse, refrescar el panel o
arrancar el análisis— y que la decisión vive en la base, no en el workflow.

## Cabecera completa, textual

```
071_carga_sin_perdida.sql — ningún archivo que el usuario mande se pierde,
y la carga entera cabe en un solo mensaje.

EL PROBLEMA, MEDIDO EN LA SEGUNDA PRUEBA DE USUARIO

El usuario mandó 101 archivos. Telegram entregó los 101 —está en el log del
proxy: 101 POST a /webhook/telegram con payload de documento, todos 200, a
~3,6/s entre las 15:52:20 y las 15:52:48 UTC—. Llegaron a `documentos` 63.

Los 38 que faltan no se perdieron en la red ni en la ingesta. Los descartó el
despachador, acá (056):

IF v_sesion.estado = 'procesando' THEN
RETURN router_respuesta(v_chat_id, 'ejecucion.ya_en_curso');
END IF;

Ese RETURN está ANTES de `router_h_recibiendo`, que es el único que emite la
acción `ingerir`. El usuario tocó Analizar a las 15:52:37 con 38 archivos
todavía en vuelo; a partir de ahí cada documento se contestó y se tiró. La
cuenta cierra exacto: los updates desde 15:52:39 (34) más el segundo 15:52:34,
que tuvo 4 webhooks y 0 documentos.

Y la respuesta que recibieron esos 38 fue:

⏳ Ya estoy trabajando en tu informe. Aguantame un momento.

que no dice en ninguna parte que el archivo se descartó. Entre 63 confirmaciones
y 38 de esas, la lectura natural es que entró todo. El sistema no mintió a
propósito; simplemente nunca dijo la verdad.

LAS TRES REGLAS QUE SALEN DE AHÍ

1. Un archivo que llega SIEMPRE se guarda. No hay estado de la conversación
en el que un documento se conteste y se tire. Pedirle al usuario que
vuelva a buscar 60 archivos entre sus carpetas es perderlo como usuario.
2. Analizar no arranca mientras estén llegando archivos. El botón no dispara:
agenda. La corrida empieza cuando pasaron `carga_silencio_segundos` sin que
entre nada nuevo.
3. La carga entera se cuenta en UN mensaje que se edita en su lugar, no en un
mensaje por archivo. Un chat con 101 confirmaciones iguales produce la
misma desconfianza que el error que estamos arreglando.

POR QUÉ EL PANEL Y NO LA PREGUNTA "¿SON TODOS?"

La 042 ya había sacado el mensaje por archivo y lo había reemplazado por un
debounce que pregunta "¿son todos?" cuando el usuario deja de mandar. Eso
resolvía la metralleta pero no la certificación: la pregunta no dice CUÁNTO
entró, así que el usuario no tiene con qué comparar contra lo que mandó. El
panel es la misma idea llevada hasta el final: un solo mensaje, siempre el
mismo, que dice cuántos archivos y cuántos movimientos van, y que trae el
botón. La 049 puso ese botón en el mensaje de "mandame los archivos" porque no
había mejor lugar; ahora sí lo hay, y encima se fija (`pinChatMessage`) para
que el usuario no tenga que volver a buscarlo.

El debounce de wf_ingesta no se toca en su forma: sigue siendo esperar y
preguntar "¿sigo siendo el último?". Lo que cambia es a quién le pregunta —
ahora a `carga_evaluar`, que decide entre callarse, refrescar el panel o
arrancar el análisis— y que la decisión vive en la base, no en el workflow.

LO QUE ESTA MIGRACIÓN NO HACE, A PROPÓSITO

No pone los topes del plan free (movimientos, archivos, informes por mes) ni
corrige el consentimiento: eso es 072, y necesita decidir qué pasa con un
archivo que entra por encima del tope, que es una conversación distinta. Acá
solo se garantiza que el archivo NO SE PIERDE; qué se hace con él después es
la migración siguiente.

=============================================================================
1. Lo que la sesión necesita recordar
=============================================================================
`panel_mensaje_id` es el mensaje que se edita en cada refresco. Vive en una
columna y no en `contexto` porque los workflows lo leen y lo escriben en cada
archivo que entra: una bolsa jsonb para algo que se toca 101 veces en 28
segundos es pagar un parseo por nada.

`analisis_pedido_en` es el botón ya tocado. Que sea una marca de tiempo y no
un boolean permite distinguir "lo pidió recién" de "lo pidió hace media hora y
algo se colgó", que es lo que va a mirar el reaper cuando haga falta.
```
