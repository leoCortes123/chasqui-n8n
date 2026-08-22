---
id: INGESTA-002
dominio: ingesta
estado: vigente
fecha: 2026-08-19
titulo: Ningún archivo que el usuario mande se pierde, y el análisis espera a que dejen de llegar
invariantes:
  - un archivo que llega siempre se guarda, en cualquier estado de la conversación
  - pedir el análisis agenda, no arranca; la corrida empieza tras carga_silencio_segundos sin archivos nuevos
  - la carga entera se cuenta en un mensaje que se edita en su lugar, no en un mensaje por archivo
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: [INGESTA-001, CORE-002]
implementada_en: [agent-context/history/migraciones/071_carga_sin_perdida.sql]
afecta: [carga_evaluar, carga_panel, carga_resumen, router_h_recibiendo]
procedencia: cabecera de la migración 071 (CAND-071), promovida el 2026-08-19
---

## Problema medido

En una prueba de usuario entraron 101 archivos y se perdieron 38 en silencio: el
estado de la conversación contestaba y tiraba el documento. Pedirle a alguien
que vuelva a buscar 60 archivos entre sus carpetas es perderlo como usuario.

Y el otro extremo: 101 archivos en 28 segundos abrían 101 ejecuciones y 101
mensajes de confirmación idénticos. Un chat con 101 confirmaciones produce la
misma desconfianza que el error que se estaba arreglando.

## Decisión

1. **Todo archivo se guarda**, siempre, sin importar el estado de la sesión.
2. **El botón agenda, no dispara.** `/listo` deja la marca `analisis_pedido_en`
   y `carga_evaluar` arranca cuando pasaron `carga_silencio_segundos` sin que
   entre nada nuevo. El último archivo que llega es el que dispara.
3. **Un solo panel** que se edita en su lugar y cuenta la carga completa:
   cuántos entraron, cuántos fallaron y por qué.

## Alternativas descartadas

- **Preguntar "¿son todos?".** La 042 ya lo había intentado; el usuario que
  sigue mandando archivos no contesta preguntas, y la respuesta llegaba tarde.
- **Arrancar en el primer `/listo`.** Es lo que producía una ejecución por
  archivo, y lo que hace que un análisis corra sobre datos a medio cargar.

## Consecuencias

Cualquier prueba automatizada que mande archivos y pida el análisis en el mismo
segundo mide el comportamiento anterior a esta decisión: tiene que esperar el
silencio, como espera una persona. `bin/prueba_ciclo_vida.py` lo hace leyendo el
parámetro, no con un número fijo.
