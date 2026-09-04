# Índice de decisiones

Generado por `bin/gen_indice_decisiones.py`. **No editar a mano.**

21 decisiones (21 vigentes, 0 superadas o descartadas) · 0 candidatos sin promover en `candidatos/`

## alertas

| id | estado | título | invariantes |
|---|---|---|---|
| [`ALERTAS-001`](ALERTAS-001.md) | ✅ vigente | Chasqui habla primero, pero un bot que avisa de más lo silencian | 4 |

## base

| id | estado | título | invariantes |
|---|---|---|---|
| [`BASE-001`](BASE-001.md) | ✅ vigente | El baseline instala producto, nunca entorno ni lo que el sistema aprendió de un cliente | 3 |

## contenido

| id | estado | título | invariantes |
|---|---|---|---|
| [`CONTENIDO-001`](CONTENIDO-001.md) | ✅ vigente | El comportamiento vive en filas, no en nodos ni en código | 3 |

## core

| id | estado | título | invariantes |
|---|---|---|---|
| [`CORE-001`](CORE-001.md) | ✅ vigente | Postgres calcula, el LLM interpreta y redacta | 4 |
| [`CORE-002`](CORE-002.md) | ✅ vigente | Los datos nunca se destruyen por el plan del usuario | 3 |
| [`CORE-003`](CORE-003.md) | ✅ vigente | Una recomendación persiste después de la ejecución que la produjo | 2 |
| [`CORE-004`](CORE-004.md) | ✅ vigente | Toda pieza nueva justifica su entrada o no entra | 3 |

## datos

| id | estado | título | invariantes |
|---|---|---|---|
| [`DATOS-001`](DATOS-001.md) | ✅ vigente | El stock declara de dónde salió y lo estimado no se disfraza de dato | 3 |

## documentacion

| id | estado | título | invariantes |
|---|---|---|---|
| [`DOCS-001`](DOCS-001.md) | ✅ vigente | La documentación descriptiva vive en una sola capa, agent-context/, y docs/ deja de existir | 3 |

## entrega

| id | estado | título | invariantes |
|---|---|---|---|
| [`PRODUCTO-002`](PRODUCTO-002.md) | ✅ vigente | Los resultados se entregan en el chat y en el portal, nunca como PDF | 2 |

## hallazgos

| id | estado | título | invariantes |
|---|---|---|---|
| [`HALLAZGOS-001`](HALLAZGOS-001.md) | ✅ vigente | El semáforo tiene seis notas y la que no se puede calcular no promedia | 3 |

## informe

| id | estado | título | invariantes |
|---|---|---|---|
| [`INFORME-001`](INFORME-001.md) | ✅ vigente | El informe receta, declara su base, y toda cifra suya existe antes de llamar al modelo | 3 |

## ingesta

| id | estado | título | invariantes |
|---|---|---|---|
| [`INGESTA-001`](INGESTA-001.md) | ✅ vigente | El formato de un archivo se reconoce por su huella y se resuelve sin el modelo siempre que se pueda | 3 |
| [`INGESTA-002`](INGESTA-002.md) | ✅ vigente | Ningún archivo que el usuario mande se pierde, y el análisis espera a que dejen de llegar | 3 |

## migraciones

| id | estado | título | invariantes |
|---|---|---|---|
| [`MIGRACION-001`](MIGRACION-001.md) | ✅ vigente | Cambiar la firma de una función obliga a borrar la anterior en la misma migración | 3 |

## planes

| id | estado | título | invariantes |
|---|---|---|---|
| [`PLANES-001`](PLANES-001.md) | ✅ vigente | El permiso se pide donde se entienden sus consecuencias, la IA se declara, y el plan limita lectura | 4 |

## portal

| id | estado | título | invariantes |
|---|---|---|---|
| [`PORTAL-001`](PORTAL-001.md) | ✅ vigente | Ninguna función es pública por defecto y el negocio sale del JWT | 4 |

## proceso

| id | estado | título | invariantes |
|---|---|---|---|
| [`PROCESO-001`](PROCESO-001.md) | ✅ vigente | Un cambio empieza por un pedido escrito, no por una conversación | 5 |
| [`PROCESO-002`](PROCESO-002.md) | ✅ vigente | El pedido es el expediente y Quipu es la prueba; la norma no se muda | 6 |

## producto

| id | estado | título | invariantes |
|---|---|---|---|
| [`PRODUCTO-001`](PRODUCTO-001.md) | ✅ vigente | El público son pymes que ya llevan números digitales, no tiendas de barrio sin registros | 2 |

## router

| id | estado | título | invariantes |
|---|---|---|---|
| [`ROUTER-001`](ROUTER-001.md) | ✅ vigente | El router es un despachador delgado con un handler por estado | 3 |

---

`candidatos/` no es normativo: es material extraído de migraciones, de la
memoria de Claude y de los transcripts, pendiente de revisión humana.
