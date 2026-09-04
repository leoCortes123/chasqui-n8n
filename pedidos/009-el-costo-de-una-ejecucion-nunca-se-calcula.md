---
id: P-009
titulo: El costo de una ejecución nunca se calcula, y la documentación afirma que sí
dominio: core
clasificacion: defecto
estado: propuesto
decisiones: [CORE-001, DOCS-001, CONTENIDO-001]
decision_nueva: null
migracion: null
abierto: 2026-08-22
cerrado: null
---

## Evidencia

Tercera prueba de usuario, 2026-08-22, negocio 168, ejecución 1:

```
tokens_prompt 13.361 · tokens_salida 1.052 · costo 0
```

`parametros` tiene `costo_por_1k_tokens_usd = 0.0003` desde el baseline. El costo
real de esa corrida es unos 0,0043 USD; la base dice 0, y `v_consumo_negocio` y
`admin_reporte` publican ese 0 como si fuera una medición.

Y `agent-context/operations/guia-tecnica.md:1244` afirma lo contrario de lo que
hace el código: *"El costo se estima con `parametro('costo_por_1k_tokens_usd')`.
Cada ejecución guarda `tokens_prompt`, `tokens_salida` y `costo` — auditoría
real, no estimada."* Eso es falso hoy, y `DOCS-001` dice que la descripción
vigente vive en `agent-context/`: una descripción que miente es peor que no
tenerla. Ya está anotado como `DISC-I6`.

## Causa

`db/actual/funciones/ejecucion_cerrar.sql:16-21` copia
`coalesce((p_resultado ->> 'costo')::numeric, costo)`. El único llamador es el
nodo `Cerrar` de `wf_ejecutar`, cuyo payload manda `texto`, `tokens_prompt` y
`tokens_salida`, y nunca `costo`. La columna se queda en su `DEFAULT 0`
(`db/actual/tablas/ejecuciones.sql:12-14`). El parámetro no tiene ningún lector
en todo el repo.

El cupo no se rompe porque se mide en tokens (`negocios.cupo_tokens_mes`), no en
pesos. Lo que se rompe es la auditoría de consumo.

## Cambio

1. `ejecucion_cerrar` calcula el costo cuando `p_resultado` no trae uno:
   `(tokens_prompt + tokens_salida) / 1000 * parametro(negocio, 'costo_por_1k_tokens_usd')`.
   La cuenta la hace SQL y el workflow sigue transportando sólo tokens
   (`CORE-001`). Sin cambio de firma, así que no hay sobrecarga que borrar.
2. Decidir con el humano si el parámetro se parte en dos —prompt y salida, que es
   como cobra el proveedor—. Si se parte, la migración **borra** el parámetro
   viejo en la misma migración.
3. Corregir la frase de `agent-context/operations/guia-tecnica.md:1244` en el
   mismo commit (`DOCS-001`).

## Tareas

- [ ] decidir con el humano: un parámetro o dos (prompt/salida)
- [ ] migración (número al aprobar): `ejecucion_cerrar` con el cálculo, y el
      parámetro nuevo si se parte
- [ ] corregir `agent-context/operations/guia-tecnica.md:1244`
- [ ] regenerar: `bash bin/gen_estado_sql.sh`
- [ ] caso en `db/pruebas/aceptacion.sql`: cerrar una ejecución con 1.000 + 500
      tokens ⇒ `costo = 0.00045` y `v_consumo_negocio.costo_mes > 0`
- [ ] `bash bin/verificar.sh`

## Verificación

`select tokens_prompt, tokens_salida, costo from ejecuciones order by id desc
limit 1` devuelve un costo distinto de cero y consistente con la tarifa.

## R-IV

Permite medir: sin costo por ejecución no se puede decir cuánto cuesta servir a
un negocio, y por lo tanto no se puede decidir ningún plan.
