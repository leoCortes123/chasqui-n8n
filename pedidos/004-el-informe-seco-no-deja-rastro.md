---
id: P-004
titulo: Un informe que sale seco no deja rastro de por qué salió seco
dominio: informe
clasificacion: defecto
estado: propuesto
decisiones: [INFORME-001, CORE-001, DOCS-001]
decision_nueva: null
migracion: null
abierto: 2026-08-22
cerrado: null
---

## Evidencia

Tercera prueba de usuario, 2026-08-22, negocio 168, ejecución 1. El informe
entregado termina con:

```
<i>Nota: no pude verificar el texto del análisis, así que va la lista seca de lo
que encontré.</i>
```

Es la plantilla `informe.sin_narracion`, que `informe_render.sql:228` agrega
cuando la estructura viene con `narrado = false`. En la base no queda **nada
más**: `ejecuciones` guarda `estado='completada'`, los tokens y el texto, y no
dice que la corrida cayó al fallback, cuántos intentos hubo, ni cuál de las tres
razones lo causó.

`INFORME-001` dice que el informe seco "es una entrega válida y no un modo
degradado". De acuerdo — pero también dice que el validador y el formateador
tienen que hablar el mismo idioma, y esa afirmación sólo se puede sostener
midiendo. Hoy no hay con qué: la única forma de saber que esta corrida salió
seca fue leer el texto entregado. Ya está anotado como `DISC-I7` en
`agent-context/audit/discrepancies.md`.

## Causa

`bin/gen_wf_ejecutar.py` — la cadena es
`ArmarLLM → DeepSeek1 → Extraer1 → Render1 → Validar1 → Cifras1ok?` y, si da
falso, un segundo intento y después `SecaSQL → EstructuraSeca → RenderSeco →
TextoSeco`. La condición del IF junta tres causas distintas en un booleano:

```
$json.v.ok === true && $('Extraer1').first().json.invalido !== true && !!$('Render1').first().json.texto
```

cifra inventada (`validar_cifras` devolvió `inventadas`), JSON truncado
(`finish_reason === 'length'`) o render vacío. `narrado` viaja en el contexto
hasta `RespFinal` y muere ahí: el nodo `Cerrar` llama a
`ejecucion_cerrar(id, 'completada', jsonb_build_object('texto', …,
'tokens_prompt', …, 'tokens_salida', …))` y no manda nada más
(`db/actual/funciones/ejecucion_cerrar.sql:16-21`).

## Cambio

1. `ejecuciones` gana `narrado boolean` y `diagnostico jsonb`.
2. Entran por `p_resultado` de `ejecucion_cerrar`, **sin tocar la firma**: es la
   misma vía por la que ya entran `tokens_prompt` y `tokens_salida`, así que no
   hay sobrecarga que borrar (`MIGRACION-001` no aplica porque no hay firma
   nueva).
3. `bin/gen_wf_ejecutar.py`: el `CierreSQL` manda `narrado` y un `diagnostico`
   con `motivo` (`cifra_inventada` | `json_truncado` | `render_vacio`),
   `intentos` y las `inventadas` que devolvió `validar_cifras` en cada vuelta.
4. Vista `v_informes_secos` (negocio, fecha, motivo, intentos, cifras
   rechazadas), para poder responder "cuántas corridas caen al seco y por qué"
   sin abrir n8n.

No viola `CORE-001`: nada de esto es una cifra del informe, es telemetría de la
corrida. Y no cambia la entrega: el informe seco sigue siendo una entrega válida.

## Tareas

- [ ] migración (número al aprobar): columnas `narrado` y `diagnostico`,
      `ejecucion_cerrar` que las lee de `p_resultado`, vista `v_informes_secos`
- [ ] `bin/gen_wf_ejecutar.py`: mandar `narrado` y `diagnostico` en el cierre
- [ ] regenerar: `python3 bin/gen_wf_ejecutar.py && bash bin/importar-workflows.sh`
- [ ] regenerar: `bash bin/gen_estado_sql.sh`
- [ ] caso en `db/pruebas/aceptacion.sql`: una ejecución cerrada con
      `narrado=false` y motivo `cifra_inventada` aparece en `v_informes_secos`
- [ ] `bash bin/verificar.sh`

## Verificación

`select * from v_informes_secos` devuelve la corrida de prueba con su motivo, y
una corrida narrada no aparece.

## R-IV

Mejora la recomendación: sin medir cuántos informes caen al seco y por qué, la
calidad de la narración es una impresión. Con la vista es un número que se puede
bajar.
