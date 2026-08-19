---
id: PLANES-001
dominio: planes
estado: vigente
fecha: 2026-08-19
titulo: El permiso se pide donde se entienden sus consecuencias, la IA se declara, y el plan limita lectura
invariantes:
  - el menú se puede mirar sin autorizar nada; el permiso se pide al elegir una opción que entrega datos
  - al aceptar, el proceso sigue solo: el consentimiento no hace perder el paso que el usuario estaba dando
  - que el análisis lo hace una IA que puede equivocarse se declara antes de aceptar y al pie de cada informe
  - un usuario nuevo recibe su negocio automáticamente; nadie queda sin poder cargar
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: [CORE-002, PRODUCTO-001]
implementada_en: [docs/historico/migraciones/050_negocio_automatico.sql, docs/historico/migraciones/051_consentimiento_y_plan_free.sql]
afecta: [usuario_de_canal, plan_desde, mov_visibles, router_procesar_mensaje]
procedencia: cabeceras de las migraciones 050 y 051 (CAND-050, CAND-051), promovidas el 2026-08-19
---

## Problema medido

**El permiso llegaba antes que el sentido.** El primer mensaje que no fuera
`/start` chocaba contra "necesito tu permiso para tratar los datos de tu
negocio": una frase sola, antes de que el usuario supiera qué hace el bot, y al
aceptar volvía a la bienvenida perdiendo el paso que estaba dando.

**Nadie creaba la fila de `negocios`.** Los que había se habían insertado a
mano. Un usuario nuevo —o cualquiera después de `limpiar_datos.sql`— quedaba con
`usuarios.negocio_id` en NULL y **cada** archivo moría en el INSERT de
`documentos` por la restricción not-null. Y moría **mudo**: el nodo abortaba el
workflow, el usuario mandaba cinco archivos, no le contestaba nadie, y al tocar
Analizar le decía "no cargaste ninguno".

## Decisión

El menú se mira sin autorizar nada. El permiso se pide al **elegir** una opción,
que es cuando de verdad se van a entregar datos, y el botón se lleva puesto lo
que el usuario tocó (`acepto:svc:ventas_compras`), así que al aceptar el proceso
continúa sin repetir el clic.

La IA se declara en los dos momentos en que importa: en el consentimiento —antes
de aceptar— y al pie de cada informe —cuando se está leyendo el resultado—.

El negocio se crea solo en `usuario_de_canal`, que corre en cada mensaje
entrante: cubre al usuario nuevo y al que quedó sin negocio. El nombre es un
marcador; el real lo pone el dueño en el portal, y el `tipo` queda en NULL
porque se pregunta con botones al elegir servicio.

El plan **free** limita la ventana de lectura (`plan_free_meses_historia`), y
nada más: lo que entra se guarda completo y aparece solo al ampliar el plan
(`CORE-002`).

## Alternativas descartadas

- **Pedir el consentimiento en el primer mensaje.** Es lo que había: se pide
  permiso para algo que el usuario todavía no sabe qué es.
- **Crear el negocio en un alta explícita.** Es un paso más antes del primer
  valor entregado, y el que lo salte vuelve al fallo mudo.

## Consecuencias

`limpiar_datos.sql` deja el sistema utilizable: el primer mensaje reconstruye
usuario y negocio por la ruta real. Es lo que permite hacer pruebas de usuario
sobre una base recién instalada sin sembrar nada a mano.
