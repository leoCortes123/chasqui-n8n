---
id: CAND-029
dominio: cerebro
estado: candidato
titulo: 029_servicios_identidades_conocimiento.sql — los tres cimientos de la Fase 1
invariantes: []          # llenar a mano al promover
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: []
implementada_en: [docs/historico/migraciones/029_servicios_identidades_conocimiento.sql]
afecta:
  - IF   # ya no existe en db/actual/
  - conocimiento_buscar
  - conocimiento_guardar
  - conocimiento_pendiente_registrar
  - ejecucion_preparar
  - hallazgos_generar   # ya no existe en db/actual/
  - norm_pregunta
  - usuario_de_canal
  - usuario_de_telegram
  - v_conocimiento_cobertura   # ya no existe en db/actual/
  - v_conocimiento_faltante   # ya no existe en db/actual/
procedencia: cabecera de docs/historico/migraciones/029_servicios_identidades_conocimiento.sql, commit 7eb606e 2026-08-14
---

> **Candidato, no decisión.** Extraído automáticamente el 2026-08-18.
> Nada de acá gobierna hasta que se revise, se le fije estado y se
> mueva a `decisiones/`.

## Cabecera completa, textual

```
029_servicios_identidades_conocimiento.sql — los tres cimientos de la Fase 1
del plan de producción (docs/PLAN_PRODUCCION.md). Ninguno agrega workflows:
los tres convierten en filas cosas que hoy están cableadas.

1. servicios.funcion_hallazgos — hoy ejecucion_preparar llama hallazgos_generar
con el nombre escrito en el código (008:45). Cualquier servicio nuevo con
otros números recibiría los hallazgos de ventas-compras. Es el bloqueador #1
del plan: sin esta columna, cada servicio nuevo toca n8n.

2. identidades — usuarios.telegram_user_id es la identidad del sistema. Para
que exista WhatsApp (Fase 3) y la sesión del portal (Fase 1) hace falta un
usuario con varias identidades, no una columna por canal.

3. conocimiento / conocimiento_pendiente — lo que el negocio sabe de sí mismo
y, sobre todo, lo que no supo contestar. Esa segunda tabla es el motor:
no se le pide al dueño que documente su negocio, se le cosechan las
preguntas reales ordenadas por frecuencia.

Nota sobre validar_cifras: NO hace falta tocarla. Valida contra el jsonb que
le pasa wf_ejecutar, que es lo que devolvió funcion_hallazgos. Al despachar
por servicio, las cifras del cotizador o de la consulta entran por el mismo
camino que las de ventas-compras y quedan permitidas solas. El cambio #3 de la
sección 5 del plan se resuelve sin código.

=============================================================================
1. servicios.funcion_hallazgos
=============================================================================
```
