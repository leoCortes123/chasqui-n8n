# Chasqui — auditoría, roadmap y plan de ejecución

*Documento vivo. Es la hoja de ruta vigente; `PLAN_PRODUCCION.md` quedó como
registro histórico de las Fases 1-4 viejas.*

---

## ESTADO — última actualización 2026-08-15

| Fase | Estado | Migración |
|---|---|---|
| **A1** Historia completa | ✅ **hecha y verificada** | `053_historia_completa.sql` |
| **A2** Inventario declarado | ✅ **hecha y verificada** | `054_inventario_declarado.sql` |
| **A3** Impacto tipado + fix de `validar_cifras` | ✅ **hecha y verificada** | `055_impacto_tipado.sql` |
| **A4** Router modular | ✅ **hecha y verificada** | `056_router_modular.sql` |
| **A5** Limpieza + interfaz de matching | ✅ **hecha y verificada** | `057_limpieza.sql` |
| **B1** Snapshot del estado empresarial | ⏭️ **siguiente** | `058_snapshot_negocio.sql` |
| B2-B4, C, D, E, F | pendientes | — |

**La Fase A está cerrada.** Las cuatro restricciones globales se sostienen, los
cinco hallazgos que ordenaban el roadmap (H1-H5) están resueltos, y C3 —el
bloqueo declarado de la Fase C— también.

### Lo que dejó A3

**El informe narrado volvió a funcionar.** La prueba de aceptación de §7bis
—`cayo_a_seco` en `f`— pasa: ejecución `3`, `tokens_salida=5244`,
`validar_cifras(texto, hallazgos) = {"ok": true, "inventadas": []}`, con el
modelo citando "142,3 días" y "0,295 unidades" sin ser castigado por copiar
bien. Las ejecuciones `1` y `2`, anteriores al fix, siguen en `t`.

El extractor de cifras permitidas ahora expande cada número de los hallazgos con
la misma `cifra_variantes` (026) que ya se aplicaba al texto del modelo, y lo
hace **por unión con la extracción vieja**, nunca reemplazándola: el conjunto
permitido es un superconjunto estricto del anterior (verificado: 41 → 53 cifras,
las 12 nuevas son lecturas alternativas de cifras que el propio SQL escribió), de
modo que nada de lo que hoy se acepta puede empezar a rechazarse. Comprobado que
una cifra realmente inventada se sigue rechazando (R-I intacta).

**H4 dejó de ser teórico.** Con los datos de prueba (`v_base_mes` = $264.082) el
orden pasó de:

| Antes | Ahora |
|---|---|
| 1. ACEITE — plata quieta $386.400 — **alta** | 1. ACEITE — `capital` $386.400 — **alta** |
| 2. ARROZ — plata quieta $100.800 — **alta** | 2. YOGURT — `unico` $22.416 — **media** |
| 3. YOGURT — se agota $22.416 — **alta** | 3. ARROZ — `capital` $100.800 — **media** |
| 4. Dependencia — media | 4. Dependencia — `mensual` — media |

O sea: $100.800 dormidos en arroz dejaron de ser "prioridad alta", y quedarse sin
yogurt —que es lo accionable esta semana— le pasó por encima. Los umbrales por
tipo (`mensual` 2/0.5%, `unico` 10/3%, `capital` 50/20% del movimiento mensual)
quedaron en `parametros`, calibrables por negocio como todos los demás.

**Sin scoring compuesto**, como estaba previsto: ni confianza, ni urgencia, ni
recurrencia. Solo clasificación y priorización.

**Incertidumbre que queda abierta**: los umbrales de `unico` y `capital` se
eligieron por razonamiento sobre un solo negocio de prueba, no por evidencia. Son
parámetros, así que se recalibran sin migración; pero hasta ver varios negocios
reales no hay con qué defender los números exactos.

### Lo que dejó A4

El router pasó de 356 líneas en una función a un despachador de ~40 y seis
piezas reemplazables una por una. **Cero cambios de comportamiento**, y está
medido: se armó un banco de **61 casos** (`db/pruebas/router_casos.sql`) que
recorre los cinco estados —sin autorizar, autorizado sin sesión, intake,
recibiendo, procesando—, los reportes de admin, el caso de un solo servicio
activo y la entrada por WhatsApp, y se corrió **antes y después** de la
migración: salida byte a byte idéntica. Cada caso se ejecuta en un subbloque que
se revierte, así que ninguno contamina al siguiente y el banco no deja rastro en
la base; sirve tal cual para las fases que vienen.

Verificado aparte el detalle que motivó separar `router_h_admin`: con una sesión
abierta de dos horas de antigüedad, un `/salud` de admin la deja intacta y un
mensaje normal sí la refresca.

**Deuda que A4 no salda**: `usuario_de_canal`, `router_arranque_servicio`,
`ingesta_resumen_sesion` y `mercado_compras_bienvenida` siguen copiándose
enteras entre migraciones. Son mucho más chicas que el router y ninguna está
en el camino crítico de B/C/D, pero el mecanismo que produjo H5 sigue vivo
para ellas.

### Lo que dejó A5

**Bajas** (por migración nueva, sin tocar el histórico): `servicios.pasos`,
`plantillas_pdf` + el contenedor Gotenberg del compose, el parámetro fantasma
`rotacion_baja_dias` y `teclado_servicios()`. `ejecucion_preparar` dejó de
consultar `plantillas_pdf` en cada corrida para publicar un dato que ningún
nodo leía desde la 020.

**El segundo menú se fue.** `teclado_servicios()` listaba los mismos servicios
que `teclado_modulo` con textos propios. Lo reemplaza `teclado_intake()`, que
sigue la regla de la 045/046 —módulo primero— con el atajo obvio cuando hay un
solo módulo activo. Efecto visible: el teclado de "¿qué querés hacer?" pasa de
`[servicios… + ✖️ Cancelar]` a `[servicios… + ❓ Cómo funciona + ⬅️ Volver]`,
que es el mismo de la bienvenida. Es el único cambio de UX de la fase, y fue a
propósito.

**El `periodo` volvió.** Restaurado en `ingesta_resumen_sesion` y en su
plantilla, que también había perdido el hueco `{{periodo}}`: la función podía
calcularlo y nadie lo mostraba. Es H5 servido en bandeja — durante tres
migraciones, quien subía dos semanas de ventas no se enteraba de que eran dos
semanas hasta ver el informe.

**Los textos salieron de los nodos.** Las cuatro frases de error de
`wf_ingesta` ("no reconocí el formato", "no pude descargarlo del chat", "se me
cayó guardándolo", "no pude leerlo") y el aviso al admin de `wf_error` vivían
dentro de nodos: cambiarles una palabra obligaba a regenerar y reimportar un
workflow. Ahora cada rama nombra su plantilla y solo pasa datos. Verificado:
`grep` de esas frases en `bin/` y `workflows/` no devuelve nada.

**C3 cerrado, que es lo que bloqueaba la Fase C.** `match_confirmar_alias`
existía desde la 005 sin un solo llamador. Ahora hay tres:

- `/matching` dejó de mentir por omisión. Antes decía "85% resuelto", que suena
  bien aunque ese 15% sea la mitad de la facturación. Ahora encabeza con
  **cuánta plata queda fuera de los cálculos** y qué porcentaje del movimiento
  es. La vista pasó a basarse en `negocios` en vez de `alias`: antes un negocio
  con movimientos sin resolver pero sin filas en `alias` no aparecía.
- `/pendientes` (admin) lista los textos sin resolver con su mejor candidato del
  trigram y cuánto dinero representa cada uno.
- **Portal, pestaña Ventas → Productos sin resolver**: la lista con el candidato
  preseleccionado y un botón para confirmar. `portal_alias_confirmar` valida que
  alias y producto sean del negocio de la sesión antes de delegar.

Probado de punta a punta con un pendiente sintético: $35.000 en 2 movimientos
(2% del movimiento) detectados y reportados por los tres caminos, el candidato
sugerido con similitud 0.577, y al confirmar los dos movimientos entran a los
cálculos y el pendiente desaparece. Un producto de otro negocio se rechaza.

**Hallado de paso**: `bin/exportar-workflows.sh` hacía `rm -rf workflows` y se
llevaba puestos los `wf_*.json` de los generadores, que son la fuente que lee
`importar-workflows.sh`. Solo no había explotado porque nadie exportaba después
de generar. Corregido: ahora borra únicamente las fotos con nombre de id. Las
fotos versionadas estaban congeladas en el 24 de julio; quedaron al día.

---

## CONFIGURACIÓN TEMPORAL QUE NO ESTÁ EN NINGUNA MIGRACIÓN

Ojo con esto al retomar, y al desplegar en otra máquina:

- **Proveedor de LLM**: se cambió a un proxy compatible con OpenAI.
  `DEEPSEEK_BASE_URL=https://opencode.ai/zen/v1` y la clave en `.env`, copiadas
  del stack `chasquiPet`. El endpoint ya no está hardcodeado: sale de esa
  variable vía `LLM_URL` en `bin/wf_lib.py`, y se hornea en el JSON al correr
  los generadores.
- **Modelo**: `prompts.modelo` y `prompts_tecnicos.modelo` están en `hy3-free`
  por un **UPDATE directo, a propósito no como migración** — es entorno, no
  comportamiento de producto. Un `migrar.sh` en limpio los deja en
  `deepseek-v4-flash`, que es lo correcto.
- **Credencial de n8n** `chasquiDs0000000001`: actualizada dentro de n8n con
  `n8n import:credentials`. Vive en la base de n8n, no en el repo.
- **Servicios**: los tres stacks vecinos (`chasquiPet`, `chasqui_tunjoSoft`,
  `chasqui_assistant`) están **detenidos**, no eliminados. Para revivir
  cualquiera: `docker compose --project-directory <ruta> start`.
  De este proyecto corren solo `postgres` y `n8n`. Gotenberg no se levanta:
  está congelado.

---

*Revisión 2. Incorpora las correcciones conceptuales del usuario y una verificación de dependencias contra el código real.*

## Contexto

Chasqui se redefine como **plataforma de inteligencia y asistencia empresarial para pymes, no un ERP**. El producto es el análisis: convertir ventas, compras, inventario, facturas y proveedores en diagnósticos, oportunidades y acciones, con el ciclo **detectar → explicar → cuantificar → recomendar → ejecutar**, sobre un cerebro acumulativo del negocio, con IA como interfaz y nunca como fuente de verdad.

La pregunta que gobierna toda decisión de aquí en adelante:

> ¿Esta pieza hace que Chasqui entienda mejor el negocio, recomiende algo mejor o permita ejecutar una decisión?

Si la respuesta es no, queda fuera de prioridad.

---

## 0. Restricciones globales del roadmap

Estas cuatro reglas son **restricciones**, no recomendaciones. Ninguna migración de este roadmap puede violarlas, y cada fase se verifica contra ellas.

| # | Regla | Cómo se verifica |
|---|---|---|
| **R-I** | **Postgres calcula; el LLM interpreta y redacta.** Ninguna cifra, umbral, regla financiera ni priorización puede vivir en un prompt ni derivarse de la salida del modelo. | Toda cifra del informe debe existir en los hallazgos antes de llamar al modelo, y `validar_cifras` debe seguir rechazando lo que no esté ahí |
| **R-II** | **Los datos nunca se destruyen por el plan del usuario.** El plan limita lectura y capacidad, jamás almacenamiento histórico. | Ningún camino de escritura puede descartar filas por plan. Prueba de Historia (§7) |
| **R-III** | **Una recomendación persiste después de la ejecución que la produjo** y puede evaluarse más tarde. | Prueba de Memoria (§7) |
| **R-IV** | **Cada pieza nueva aumenta el conocimiento del negocio, mejora una recomendación, o permite ejecutar/medir una decisión.** | Justificación explícita por fase; si no se puede escribir, la pieza no entra |

**Corolario operativo de R-I**: está prohibido mover al LLM responsabilidades que hoy son de SQL. La dirección permitida es la contraria — sacar lógica de los nodos de n8n hacia Postgres.

**Congelado, sin excepciones salvo que demuestren alimentar la capacidad de análisis**: cotizador · cobro automático, suscripciones y webhook Wompi · facturación electrónica · PDF y Gotenberg · bot público · pgvector · Supabase · RLS · Directus · comparativos externos Nivel 2 y 3 (SIPSA, benchmark entre negocios).

---

## 1. Dónde está Chasqui hoy

| Eslabón | Estado | Evidencia |
|---|---|---|
| **Detectar** | ✅ Sólido | 6 reglas en `recomendaciones_negocio` (`047`), 7 vistas de cálculo (`006`), `hallazgos_compras` (`043`) |
| **Explicar** | ✅ Sólido | `informe_render` + prompt "TU TRABAJO ES REDACTAR, NO CALCULAR" (`047:993+`) |
| **Cuantificar** | ✅ Corregido en A2 y A3 | `impacto_tipo` separa flujos de stocks con umbral propio (`055`); el stock declara su `origen_stock` (`054`) |
| **Recomendar** | ✅ Sólido | Opciones condicionales por regla, prioridad relativa a `v_base_mes`, tope 2×regla / 8 total |
| **Ejecutar** | ❌ No existe | Ninguna recomendación tiene acción; nada se registra ni se mide después |
| **Cerebro acumulativo** | ❌ No existe, y hay una fuga | `hallazgos_generar` mira solo el presente; el plan free borra el pasado |
| **IA no es fuente de verdad** | ✅ Excelente | `validar_cifras` (`026`) + informe seco (`047:894`). Es el activo más valioso del proyecto |
| **Mensajería como interfaz** | ✅ Sólido | Router en SQL, dos canales, portal para lo que no cabe en el chat |

### Los cinco hallazgos que ordenan el roadmap

**H1 — El plan free destruye historia.** `movimientos_limite_plan()` (`051:60-76`) es un `BEFORE INSERT` que devuelve **NULL** para filas fuera de la ventana de 3 meses. Viola R-II frontalmente: impide el comparativo interanual, y un upgrade a plan pago **no recupera nada** — el cliente tendría que volver a subir todo.

**H2 — `consulta` no mira los números.** `conocimiento_recuperar` (`030`) hace trigram sobre la tabla `conocimiento` (FAQs y precios cargados a mano) y nada más. "¿Cómo está mi negocio?" escrito en el chat **no consulta `movimientos`, ni `salud_negocio`, ni las recomendaciones**. La pregunta insignia del producto no se responde con los datos del producto.

**H3 — El inventario es una estimación no declarada.** `v_balance_unidades` (`006:55-63`) = comprado − vendido, sin stock inicial. Sobre ese número se calculan R4 (se agota), R5 (plata quieta) y la nota de Inventario de `salud_negocio` — o sea 2 de las 6 reglas y 1 de las 5 notas. `047:245` reconoce el síntoma (coberturas negativas) y lo parchea con un texto especial en vez de arreglar el dato.

**H4 — `impacto_mes` mezcla flujos con stocks.** *(Resuelto en `055`.)* R1/R2/R3 son pesos por mes; R4 es lucro cesante del ciclo de entrega (evento único) y R5 es capital inmovilizado (un stock). Los cinco compiten en el mismo ranking `impacto_mes / v_base_mes` (`047:336-338`). R5 puede encabezar el informe por ser un acumulado: el orden de "¿qué debería hacer primero?" es incorrecto por construcción.

**H5 — `router_procesar_mensaje` va por su octava copia íntegra** *(Resuelto en `056`.)* (012, 015, 016, 024, 030, 033, 041, 042, 043, 045, 046, 051; ~300 líneas cada vez). Ya se perdió un fix por ese mecanismo: el `periodo` de `ingesta_resumen_sesion` que la 046 agregó con justificación explícita y la 051 borró sin mencionarlo.

---

## 2. Contradicciones encontradas al verificar contra el código real

*Regla aplicada: donde el roadmap y el código discrepan, manda el código.*

**C1 — A1 no es un cambio de trigger. (Corrige el roadmap anterior.)**
El filtro del plan free hoy es de **escritura**, y por eso **ningún lector tiene filtro**. Verificado: los 7 views de `006`, `recomendaciones_negocio` y `salud_negocio` (`047:105,111,119,129,301,392,404,441,492`), `hallazgos_compras` (`043:48,120,129,315`), el bloque `periodo` (`025:120`) y las 5 RPC de portal (`035:44,61,83,118,145`) leen `movimientos` **sin condición de fecha**. Si solo se cambia el trigger, el plan free desaparece en silencio y todos los negocios free pasan a analizar historia ilimitada.
**Consecuencia**: A1 debe mover el filtro de escritura a lectura en el mismo cambio. Se resuelve con **una vista `mov_visibles`** y el repunte mecánico de los lectores analíticos — no con 20 predicados repetidos.

**C2 — `documentos.filas_fuera_de_plan` cambia de significado.**
Hoy cuenta filas **descartadas**. Con A1 pasa a contar filas **guardadas pero fuera de la ventana de lectura**, y como `plan_desde` se desplaza cada mes (`051:40-50`, `date_trunc('month', current_date)`), el contador caduca solo. Decisión: se conserva la columna y el incremento (el trigger pasa a `RETURN NEW`), se acepta la caducidad porque es un dato informativo del momento de la carga, y **cambia el texto al usuario**: de "se descartaron N filas" a "N filas quedan fuera de tu ventana gratis; las guardo y se activan si pasás de plan". Esa frase, además, es un argumento de venta que hoy no existe.

**C3 — `match_confirmar_alias` no tiene ni un solo llamador.** *(Resuelto en `057`.)* Verificado en `db/`, `bin/` y `portal/`: cero referencias fuera de su propia definición (`005:93`). Los alias `origen='pendiente'` se acumulan sin salida, y un movimiento sin `producto_id` **no entra a ningún cálculo**: no tiene margen, no tiene rotación, no entra al Pareto. Es una pérdida silenciosa de datos que degrada exactamente las cifras del producto. `/matching` reporta el porcentaje pero no ofrece cómo arreglarlo.
**Consecuencia**: la resolución de pendientes debe existir **antes de la Fase C**. Si no, "¿cuál es mi producto más rentable?" se responde ignorando parte de las ventas sin decirlo.

**C4 — El snapshot tiene datos previos disponibles.** `ejecuciones.hallazgos jsonb` (`001`) ya persiste el JSON completo de cada corrida. Eso confirma la corrección del usuario (snapshot ≠ informe) y abarata B1: hay material histórico para un backfill parcial. Pero **no sirve como snapshot**: su forma cambió cuatro veces (025, 029, 043, 047) y volverá a cambiar. El snapshot debe ser tipado y versionado.

**C5 — `impacto_tipo` toca las 6 CTEs, no una.** `recomendaciones_negocio` une las reglas con `UNION ALL` posicional (`047:321-328`); las columnas deben coincidir en orden y tipo. Añadir `impacto_tipo` obliga a tocar `r_costo`, `r_proveedor`, `r_margen`, `r_agota`, `r_quieto` y `r_dependencia`.

**C6 — `v_balance_unidades` empareja sin negocio.** `006:62` hace `LEFT JOIN movimientos m ON m.producto_id = p.id`, la única vista de las siete que no incluye `negocio_id` en el join. No hay fuga entre negocios (un producto pertenece a uno solo), pero al reescribirla en A2 hay que corregir el patrón, no copiarlo.

**C7 — A2 cambia el input de tres consumidores, no de uno.** `v_balance_unidades` alimenta `v_rotacion_producto.dias_cobertura` (`006:80`), que alimenta R4 (`047:257`), R5 (`047:286-289`) y la nota de Inventario de `salud_negocio`. Los tres deben propagar el marcador `origen_stock` hasta el informe: si el stock es estimado, el informe debe decirlo.

### Hallado durante la ejecución de A2

**C10 — H3 no era teórico: producía consejos de prioridad alta equivocados.** Con los datos de prueba y stock estimado, el informe traía dos recomendaciones de *"plata quieta / prioridad alta"* ("tenés $386.400 inmovilizados", "no vuelvas a comprarlo"). Al cargar un conteo real, **esas dos desaparecen** y la nota de Inventario del índice de salud pasa de **0 a 100**. O sea: sin conteo, Chasqui estaba recomendando con seguridad lo contrario de lo que convenía, y bajando la nota del negocio por un dato que se había inventado.

**C11 — El LLM real confirma C8 en producción.** *(Resuelto en `055`.)* Dos corridas completas de `wf_ejecutar` contra el proveedor nuevo terminaron `completada` pero **ambas cayeron al informe seco**: el modelo cita "142,3 días" y "0,295 unidades" —cifras que calculó el propio SQL— y `validar_cifras` las rechaza. La rama narrada está rota hoy para cualquier negocio cuyo informe incluya R4 o R5, que es la mayoría. Refuerza que **A3 no puede postergarse**.

### Hallado durante la ejecución de A1

**C8 — `validar_cifras` castiga al modelo por copiar bien.** *(Resuelto en `055`.)* `recomendaciones_negocio` formatea con `fmt_decimal`, que usa coma decimal ("te alcanza para 83,5 días", "vendés 0,287 por día"). El conjunto de cifras permitidas se extrae con `regexp_matches(hallazgos::text, '\d+(?:\.\d+)?')`, que **parte "83,5" en `83` y `5`**. Resultado: si el modelo cita fielmente una cifra que el propio SQL calculó, `validar_cifras` la marca como inventada, fuerza el reintento y termina cayendo al informe seco.
Verificado como **anterior a A1 e independiente del plan**: con todos los datos dentro de la ventana gratuita (almacenado = visible = 10 filas, el filtro es un no-op) `validar_cifras` marca igual `["0,25"]`. En producción no rompe el informe seco —`wf_ejecutar` no valida esa rama— pero sí degrada la rama narrada, que es la normal.
Se corrige en **A3**, que ya toca `recomendaciones_negocio`. No se tocó en A1 por la regla de no hacer refactors ajenos a la fase.

**C9 — Las compuertas "¿puedo analizar ya?" del router quedaban descolgadas.** `router_procesar_mensaje` (`051:565-569`) y `mercado_compras_bienvenida` (`043:315`) consultan `movimientos` para decidir si `mercado_compras` puede correr sin archivos nuevos. Antes de A1 coincidían con el análisis por accidente (las filas viejas no existían); después ya no. Sin el cambio, el bot ofrecería "generá con lo que tengo" y la bienvenida anunciaría un gasto y un periodo que el informe no usa. **Repuntadas a `mov_visibles` dentro de A1**, porque es un efecto que A1 introduce.

*Ninguna de estas contradicciones exige cambiar arquitectura. Todas se resuelven dentro del diseño existente.*

---

## 3. Auditoría — clasificación pieza por pieza

**Categorías** — **CORE**: es el producto. **HABILITADOR**: sin esto el CORE no funciona. **SECUNDARIA**: útil, no diferencial; se mantiene, no se invierte. **ERP-DRIFT**: funcionalidad de ERP que no responde la pregunta de prioridad; congelar. **ELIMINAR**: objeto vivo muerto o duplicado.

> Las migraciones son un **log histórico y no se editan**. "ELIMINAR" significa dar de baja el **objeto vivo** (función, tabla, columna, parámetro, contenedor) mediante una **migración nueva** — nunca borrando ni modificando la migración que lo creó.

### 3.1 Motor de análisis

| Pieza | Migración | Clase | Nota |
|---|---|---|---|
| `recomendaciones_negocio` (6 reglas) | 047 | **CORE** | El corazón. A3 lo corrige (H4/C5) |
| `salud_negocio` + `semaforo`/`barra_10` | 047 | **CORE** | 5 notas, NULL si no hay datos. Bien resuelto |
| 7 vistas de cálculo | 006 | **CORE** | Base de todo. A1 y A2 las reescriben |
| `hallazgos_generar` (v4) | 006→025→029→047 | **CORE** | Publica salud + recomendaciones + tipo_negocio |
| `hallazgos_compras` (2 args) | 043→047 | **CORE** | "¿Qué debería comprar?", "¿qué proveedores me afectan?" |
| `hallazgos_compras` (1 arg) | 043 | **CORE** *(corregido en ejecución)* | **No está muerta**: la de 2 args (`047:543`) la invoca y le concatena salud/recomendaciones. Es el motor de compras. La auditoría inicial la clasificó mal |
| `validar_cifras` + `cifra_norm`/`cifra_variantes` | 008→026 | **CORE** | La garantía de R-I. No tocar sin pruebas |
| `informe_render` (v4) | 025→030→047 | **CORE** | Layout en SQL, whitelist de iconos, escape HTML |
| `informe_estructura_seca` | 031→043→047 | **CORE** | El motor de reglas sin narrar: la prueba viva de R-I |
| `ejecucion_preparar` / `ejecucion_cerrar` | 008→029 / 019→044 | **CORE** | Motor genérico + corte de cupo antes de gastar tokens |
| `servicios.funcion_hallazgos` | 029 | **CORE** | Un análisis nuevo = una fila. El mecanismo de extensión del roadmap |
| Prompts de `ventas_compras` / `mercado_compras` | 047 | **CORE** | Contrato JSON estructurado |
| `parametros` de umbrales | 003, 047 | **CORE** | Calibración por negocio |
| `tipos_negocio` + `negocios.tipo` | 046 | **CORE** | Sin él se compara contra un promedio inexistente |
| `parametros.rotacion_baja_dias` | 003 | ~~ELIMINAR~~ ✅ dado de baja en `057` | Nunca leído; reemplazado de hecho por `rotacion_lenta_dias` (047) |
| `productos.categoria` | 001 | **CORE latente** | Se mapea en la ingesta y no se agrega en ninguna métrica. Análisis gratis sin usar |

### 3.2 Datos: ingesta, matching, inventario

| Pieza | Migración | Clase | Nota |
|---|---|---|---|
| `ingesta_registrar_documento` / `_procesar_documento` / `_cargar_tabular` | 004→017→019 | **HABILITADOR crítico** | Sin datos no hay análisis |
| Aprendizaje de formatos (huella + `ingesta_identificar_tabular` + `_registrar_formato_inferido` + `prompts_tecnicos`) | 017 | **HABILITADOR crítico** | El LLM ve solo cabeceras y 5 filas; las cifras nunca pasan por el modelo. Cumple R-I |
| Compuerta de calidad (`max_pct_nulos`) | 017 | **HABILITADOR crítico** | "No inserta ni una fila" antes que corromper en silencio |
| `ingesta_parsear_dian` | 004→036 | **HABILITADOR crítico** | **Riesgo abierto**: fixtures sintéticos, sin XML real de cliente |
| Matching (`match_resolver_producto`, `_documento`, `alias`, `norm_texto`) | 005 | **HABILITADOR crítico** | La calidad del margen depende de esto |
| `match_confirmar_alias` | 005 | ~~sin interfaz~~ ✅ **HABILITADOR** — `057` le dio tres llamadores | **C3**: cero llamadores. Debe resolverse antes de la Fase C |
| `movimientos_limite_plan()` (trigger) | 051 | ~~ELIMINAR y rehacer~~ ✅ rehecho en `053` | **H1**, viola R-II |
| Stock declarado | — | **NO EXISTE** | **H3**. Bloquea la corrección de R4/R5 |
| `ingesta_resumen_documento` / `_resumen_sesion` | 017→038, 042→046→051→`057` | **SECUNDARIA** | ~~Recuperar el `periodo` que la 051 borró (H5)~~ ✅ `057` |

### 3.3 Cerebro / conocimiento

| Pieza | Migración | Clase | Nota |
|---|---|---|---|
| Servicio `consulta` (`entrada='texto'`, `consulta_iniciar`) | 030 | **CORE** | La interfaz de preguntas. **H2**: hoy no mira los números |
| `conocimiento_recuperar` | 030 | **CORE, a reescribir** | Pasa a recuperar contexto del negocio, no solo KB |
| `conocimiento` + `conocimiento_buscar` (trigram) | 029 | **HABILITADOR** | Correcto para <300 filas. Se conserva como una fuente más del contexto |
| `conocimiento_pendiente` + `v_conocimiento_faltante` | 029 | **SECUNDARIA** | Buen mecanismo, pero apunta al bot público (congelado) |
| `conocimiento.clave` / `.datos` / `origen='archivo'` | 029 | **ELIMINAR o completar** | El importador de listas de precios que motivó el índice único parcial nunca se escribió |
| Snapshot de estado empresarial | — | **NO EXISTE** | Toda la prioridad 3 depende de esto |
| Persistencia y seguimiento de recomendaciones | — | **NO EXISTE** | Viola R-III: hoy se recalculan y se tiran |

### 3.4 Interfaz: router, canales, plantillas

| Pieza | Migración | Clase | Nota |
|---|---|---|---|
| `router_procesar_mensaje` | 012…053 (8 copias) | ~~refactor obligatorio~~ ✅ partido en handlers en `056` | **H5**. Cuello de botella de todo el roadmap |
| `router_respuesta` | 024 | **HABILITADOR** | Elimina de raíz el bug de literales jsonb |
| `usuario_de_canal` / `identidades` / `canal_de_chat` / `chat_de_usuario` | 029→044→050 | **HABILITADOR** | 3 copias íntegras. `canal='portal'` anunciado y nunca creado |
| `resolver_plantilla` + `plantillas` + `teclado_markup` + `esc_html` | 002, 022, 023, 027 | **HABILITADOR** | La tesis "comportamiento como filas" |
| WhatsApp (`wa_texto`, `wa_payload`, `wf_wa_router`) | 044 | **HABILITADOR** | Construido, **no desplegado**: no hay `wfWa*.json` con ID entre los importados |
| `modulos` + `teclado_modulos`/`teclado_modulo` | 045 | **SECUNDARIA** | Menú de dos niveles |
| `teclado_servicios()` | 030 | ~~ELIMINAR (unificar)~~ ✅ reemplazado por `teclado_intake()` en `057` | Segundo menú coexistiendo con `teclado_modulo`, con textos distintos |
| `admin_reporte` + vistas de observabilidad | 008, 015 | **HABILITADOR** | `/embudo` y `/matching` son los dos que informan producto |
| `servicios.pasos` | 003 | ~~ELIMINAR~~ ✅ dado de baja en `057` | Letra muerta desde la 012 |
| Consentimiento en contexto | 051 | **HABILITADOR** | Requisito legal, bien resuelto |
| Aviso de IA | 051, 052 | **HABILITADOR** | Obligatorio bajo "IA como interfaz" |

### 3.5 Portal

| Pantalla | Migración | Clase | Nota |
|---|---|---|---|
| Seguridad (magic link, `jwt_firmar`, `portal_claim`, cero GRANT sobre tablas) | 033, 034, 039 | **HABILITADOR** | Modelo sólido. La 034 fue un no-op documentado, corregido por la 039 |
| 📊 Informes | 033 | **CORE** | La más esbozada. Destino del histórico y el comparativo |
| 📈 Ventas | 035 | **HABILITADOR** | Transparencia sobre los datos cargados |
| 💡 Conocimiento | 033 | **SECUNDARIA** | |
| 🏷️ Precios | 033/040 | **SECUNDARIA → CORE latente** | Destino natural de "aplicar el precio sugerido" (D1) |
| 🏪 Mi negocio | 033, 038 | **HABILITADOR** | El NIT habilita el lado "te deben" de la cartera |
| Cartera | 037 | **ERP-DRIFT → reconvertir (F)** | |
| Cotizaciones + `cotizacion.html` | 040 | **ERP-DRIFT — congelado** | Funciona; no recibe más trabajo |

### 3.6 Piezas ERP

| Pieza | Migración | Clase | Decisión |
|---|---|---|---|
| Cartera: `terceros`, `facturas`, `pagos`, `cartera_facturar_dian`, `v_cartera_*` | 036-038 | **ERP-DRIFT → CORE por reconversión** | Los datos ya existen y responden "¿dónde estoy perdiendo dinero?". Se justifica **solo** si alimenta `recomendaciones_negocio` como señal de liquidez (Fase F). Además está a medias: solo se llena desde XML DIAN — quien carga CSV ve la pestaña vacía para siempre |
| Cotizador | 040 | **ERP-DRIFT** | **Congelado** |
| Cobro Wompi (`router_plan`, `parametros.pago_enlace`) | 041 | **SECUNDARIA** | Monetización manual; está bien así. `/plan` puede terminar en un enlace inexistente si nadie insertó el parámetro |
| `miles(numeric)` | 041 | **HABILITADOR** | Se usa en toda la base; sobrevive a la congelación |

### 3.7 Muerto confirmado

~~`plantillas_pdf` + contenedor Gotenberg~~ ✅ dados de baja en `057`, junto con la referencia de `ejecucion_preparar` y la topología de `docs/GUIA_TECNICA` · `cifra_canonica` (ya dropeada por 026) · `plantilla_cuerpo_srv` sin variantes (N consultas fallidas por render).

### 3.8 Workflows (n8n)

| Workflow | Clase | Nota |
|---|---|---|
| `wf_ejecutar` | **CORE** | preparar → LLM → render → validar → reintento → seco → cerrar |
| `wf_ingesta` | **HABILITADOR crítico** | Descarga, extracción tabular, inferencia de mapeo |
| `wf_router` / `wf_wa_router` | **HABILITADOR** | Una sola llamada SQL cada uno. `wf_wa_router` sin desplegar |
| `wf_enviar` | **HABILITADOR** | Único punto de salida |
| `wf_error` | **HABILITADOR** | Contiene el **único INSERT directo** del sistema |
| `wf_cron` | **HABILITADOR → CORE latente** | Hoy solo reaper. Vehículo de la proactividad (E) |

**Lógica de negocio que quedó en nodos** (contradice `docs/GUIA_TECNICA.md:226` y estorba al roadmap): INSERT directo a `fallas` y clasificación transitoria por regex (`bin/gen_wf_error.py:12-36`); aviso al admin concatenado en SQL sin pasar por `plantillas` (`:40-49`); regla "¿pregunto si son todos?" como SQL ad-hoc (`bin/gen_wf_ingesta.py:267-272`); debounce de 8 s literal (`:261-262`); tamaño de muestra del LLM `slice(0,5)` fijo en el nodo y no en `prompts_tecnicos` (`:155-163`); política "un reintento y luego seco" como topología (`bin/gen_wf_ejecutar.py:228-242`); troceado `LIM = 3800` y elección de plantilla en JS (`:312-366`); `MAX_FILAS = 6` duplicado con `parametros.teclado_max_filas` (`bin/gen_wf_enviar.py:57`); copy de usuario hard-codeado (`bin/gen_wf_ingesta.py:216,292,303,311,323`).

---

## 4. Línea transversal: calidad de datos

No es una fase. Es un **criterio de aceptación que atraviesa todas las fases**: toda capacidad analítica nueva se valida recorriendo la cadena completa

```
documento → parseo → matching → movimientos → cálculo → recomendación
```

y comprobando que ningún eslabón pierde filas en silencio. Reparto de los dos problemas ya detectados:

| Problema | Dónde entra | Por qué ahí |
|---|---|---|
| **`match_confirmar_alias` sin interfaz (C3)** | **A5**, como capacidad mínima: comando de admin `/pendientes` + RPC `portal_alias_pendientes` / `portal_alias_confirmar` reutilizando la función que ya existe | Bloquea la Fase C: no se puede responder "¿cuál es mi producto más rentable?" ignorando ventas sin producto resuelto. No requiere modelo nuevo, solo exponer lo construido |
| **`ingesta_parsear_dian` sin XML real (riesgo abierto)** | **Criterio de aceptación permanente**, no una tarea | Depende de conseguir facturas reales de cliente — no es trabajo de código. Se documenta como riesgo abierto y se re-verifica en cuanto haya material. Ninguna fase se declara terminada afirmando que la ingesta DIAN es confiable |
| **Filas sin `producto_id` invisibles** | **A5**: `/matching` y el portal deben reportar cuántos movimientos y cuánto dinero quedan fuera de los cálculos | Hoy el porcentaje de aliases resueltos no dice cuánta plata representa lo no resuelto |

---

## 5. Roadmap

### Fase A — Integridad de datos

*R-IV: sin esto, el cerebro se construye sobre datos que se borran y cifras que ordenan mal.*

**A1. Historia completa** — `053_historia_completa.sql` ✅ **APLICADA 2026-08-14**
Cumple R-II. Cinco cambios en una migración, porque separarlos deja el sistema incoherente (C1):
1. `movimientos_limite_plan()` deja de devolver NULL: guarda la fila, incrementa `documentos.filas_fuera_de_plan` y `RETURN NEW`.
2. Vista nueva `mov_visibles` = `movimientos` filtrada por `plan_desde(negocio_id)` (`NULL` = sin límite; filas sin fecha siempre visibles).
3. Repunte de los **lectores analíticos** a `mov_visibles`: las 7 vistas de `006`, `recomendaciones_negocio` y `salud_negocio` (`047`), `hallazgos_compras` (`043`), el bloque `periodo` (`025`), y las RPC de `035`.
   **No se repuntan**: `match_resolver_documento` (`005`) —el matching trabaja sobre todo lo almacenado—, ni `ingesta_resumen_documento`/`_resumen_sesion` —cuentan lo que el archivo trajo, que es lo honesto—.
4. Repunte de las dos compuertas del router que preguntan "¿puedo analizar ya?" — `router_procesar_mensaje` y `mercado_compras_bienvenida` (C9).
5. Texto al usuario: de "dejé por fuera N registros" a "guardé N registros que todavía no analizo; si ampliás el plan entran solos, sin volver a mandarme nada" (C2).

**A2. Inventario declarado** — `054_inventario_declarado.sql` ✅ **APLICADA 2026-08-14**
Tabla `conteos_inventario(negocio_id, producto_id, fecha, unidades, origen)`. `v_balance_unidades` se reescribe (corrigiendo el join de C6) y expone `origen_stock`:

| `origen_stock` | Significado |
|---|---|
| `conteo` | Hay un conteo en la fecha misma: stock respaldado |
| `calculado` | Último conteo + comprado − vendido desde esa fecha |
| `estimado` | Sin conteo: comprado − vendido. **Fallback actual, conservado** |

Todo resultado con `origen_stock='estimado'` se marca como tal y **no se presenta como stock conocido**: `v_rotacion_producto`, R4, R5 y la nota de Inventario propagan el marcador hasta el texto del informe (C7). Entrada del conteo por portal (pestaña Ventas) y por formato tabular de ingesta clase `inventario`, reutilizando el aprendizaje de mapeo de `017`. Sin modelo de inventario más complejo: nada de lotes, vencimientos ni valuación.

**A3. Impacto tipado** — `055_impacto_tipado.sql` ✅ **APLICADA 2026-08-15**
*(Incorpora además el defecto C8 hallado al ejecutar A1: `validar_cifras` no reconoce las cifras con coma decimal que produce `recomendaciones_negocio`. Ver §2.)*
`recomendaciones_negocio` devuelve `impacto_tipo ∈ {mensual, unico, capital}` — añadido a las **6 CTEs** del `UNION ALL` (C5). R1/R2/R3 → `mensual`; R4 → `unico`; R5 → `capital`; R6 → `mensual` con impacto 0. La prioridad solo compara `mensual` contra `v_base_mes`; `unico` y `capital` obtienen su propio umbral. **Sin scoring compuesto**: nada de confianza, urgencia ni recurrencia todavía. Solo clasificación y priorización correctas.

### Fase A' — Estabilización arquitectónica

*Separada conceptualmente de A para las verificaciones; puede compartir ventana de ejecución si no multiplica migraciones sin necesidad.*

**A4. Router modular** — `056_router_modular.sql` ✅ **APLICADA 2026-08-15**
Partir `router_procesar_mensaje` en handlers por estado (`router_h_comandos`, `router_h_sin_sesion`, `router_h_intake`, `router_h_recibiendo`) con un despachador delgado. Cada migración futura reemplaza **un** handler, no 300 líneas. Sin esto, C, D y F pagan el impuesto de la copia íntegra y arriesgan repetir la regresión del `periodo` (H5).

*Salieron **cinco** handlers, no cuatro*: `router_h_admin` quedó aparte porque el bloque de admin corre **antes** de leer la sesión, y meterlo en `router_h_comandos` habría hecho que un `/salud` le refrescara `ultima_actividad` a una sesión que estaba por expirar. Se agregó además `router_ctx`, que arma el contexto del mensaje: es la pieza que una fase futura reemplaza para reconocer un prefijo de botón nuevo (`rec:` de D1, por ejemplo) sin tocar ningún handler.

**El contrato**: un solo argumento `ctx jsonb` —agregarle un dato no cambia ninguna firma— y `NULL` como "no me toca, seguí". `NULL` es inequívoco porque `router_respuesta` construye siempre un objeto, incluso cuando la respuesta no lleva texto.

**A5. Limpieza y calidad de datos** — `057_limpieza.sql` ✅ **APLICADA 2026-08-15**
Dar de baja (por migración nueva, nunca editando el histórico): `servicios.pasos`, `plantillas_pdf` + Gotenberg del compose, `parametros.rotacion_baja_dias`, `teclado_servicios()`. *(`hallazgos_compras(bigint)` sale de esta lista: está viva.)* Recuperar el `periodo` de `ingesta_resumen_sesion`. Bajar a `plantillas` los textos hard-codeados de `gen_wf_ingesta.py` y `gen_wf_error.py`. Corregir `docs/GUIA_TECNICA.md:39,50`.
**Más la capacidad mínima de matching (C3)**: `/pendientes` para admin y RPC `portal_alias_pendientes` / `portal_alias_confirmar` sobre `match_confirmar_alias`, y `/matching` reportando cuánto **dinero** queda fuera de los cálculos, no solo cuántos aliases.

### Fase B — El cerebro acumulativo

*R-III y R-IV. Es lo que convierte a Chasqui de analizador de archivos en el sistema que conoce el negocio.*

**B1. Snapshot del estado empresarial** — `058_snapshot_negocio.sql`
Tabla `snapshots_negocio(negocio_id, fecha, version, periodo daterange, salud jsonb, metricas jsonb, origen)`.
**El snapshot es estado empresarial, no una copia del informe renderizado.** Contiene datos estructurados y versionados suficientes para comparar estados futuros **aunque cambie por completo el diseño del informe**: márgenes, coberturas, gasto por proveedor, notas de salud, totales por periodo. No contiene texto narrado, ni HTML, ni la estructura de secciones. `ejecuciones.hallazgos` (C4) sirve de material para un backfill parcial, pero **no es el snapshot**: su forma cambió cuatro veces y volverá a cambiar. De ahí la columna `version`.

**B2. Recomendaciones persistentes** — `059_recomendaciones_persistentes.sql`
Cumple R-III. Tabla `recomendaciones(negocio_id, regla, clave_objeto, titulo, impacto, impacto_tipo, prioridad, estado, vista_en, cerrada_en, ...)` con estados **`nueva | vigente | resuelta | ignorada | caducada`**.

**Separación de dimensiones desde el diseño**: el **estado de ejecución** (¿el dueño hizo algo?) y el **resultado empresarial** (¿sirvió?) son dos ejes distintos y no se colapsan en una columna. "Aplicar precio sugerido" puede quedar *ejecutada por el usuario* y aun así producir un resultado *positivo, neutro o negativo*. B2 no está obligada a implementar el eje de resultado —lo necesita D3—, pero su modelo **no puede impedirlo ni obligar a remodelar** las recomendaciones después: el eje de resultado se acomoda como columnas/tabla anexa sin tocar `estado`.

`recomendaciones_negocio` pasa de función pura a función + upsert. **La detección automática de resolución se mantiene**: si el costo bajó, si el margen subió, si el stock se repuso, la recomendación se cierra sola con `cerrada_por='dato'` — distinguible de `cerrada_por='accion_usuario'`.

**B3. Reglas comparativas (Nivel 1 completo)** — `060_reglas_comparativas.sql`
`hallazgos_generar` recibe el snapshot anterior. Reglas contra el propio historial: producto que dejó de venderse, proveedor que subió tres veces en el año, margen deteriorado dos periodos seguidos, mes por debajo del mismo mes del año anterior. **Depende de A1**: sin historia no hay comparativo.

**B4. Perfil consolidado** — `061_perfil_negocio.sql`
Vista `v_perfil_negocio`: productos, proveedores, estacionalidad, márgenes típicos, problemas recurrentes (desde `recomendaciones`), acciones tomadas. Es el objeto que consumen la Fase C y el portal. Casi todo el dato existe; falta la consolidación.

### Fase C — Preguntar a los números

*Cierra H2. "¿Cómo está mi negocio?" debe consultar realmente los datos de Chasqui.*

Arquitectura obligatoria, sin excepciones (R-I):

```
intención → consulta/agregado determinístico (SQL) → contexto estructurado
          → LLM (solo redacta) → respuesta → validar_cifras
```

**Nunca se pasan movimientos completos al LLM para que calcule.** La cifra final siempre proviene de SQL.

**C1. `conocimiento_recuperar` → `contexto_negocio_recuperar`** — `062_consulta_sobre_numeros.sql`
La `funcion_hallazgos` de `consulta` compone: KB (`conocimiento_buscar`, se conserva) + último snapshot (B1) + recomendaciones vigentes (B2) + agregados precalculados según la intención. Cambia el `sistema` del prompt de `consulta` para redactar sobre ese contexto — **sin añadirle ninguna regla de cálculo**.

**C2. Intenciones como contrato de datos** — `063_intenciones_consulta.sql`
`intenciones` **no es un despachador de funciones**: es un contrato que produce un contexto estructurado. Cada intención determina:

| Campo | Qué declara |
|---|---|
| `metrica` | Qué se pide (ventas, margen, gasto, cobertura, utilidad…) |
| `periodo` | Ventana temporal, resuelta a fechas concretas |
| `filtros` | Producto, proveedor, categoría, tipo de movimiento |
| `comparativo` | Contra qué (periodo anterior, mismo mes del año pasado, snapshot) |
| `agregados` | Qué necesita el modelo para redactar, ya calculado |

Una intención nueva es una fila — mismo patrón que `servicios.funcion_hallazgos`.
**Las ocho preguntas de la definición de producto son las pruebas de aceptación de esta fase.**

### Fase D — Ejecutar (dentro de Chasqui)

*Sin canal saliente a terceros.*

**D1. Acciones sobre la recomendación** — `064_acciones.sql`
Botones en el informe: **✅ Ya lo hice** / **⏭️ No aplica** / **💲 Aplicar precio sugerido**. Aplicar precio escribe en `conocimiento` tipo `precio` (que ya existe y ya tiene pantalla) y registra la acción contra la recomendación de B2.

**D2. Lista de pedido** — `065_pedido.sql`
Consolida las recomendaciones R4 en una lista de compra (producto, unidades, proveedor más barato conocido, costo estimado), entregada en el portal. No se envía a nadie.

**D3. El resultado se mide** — activa el eje de resultado previsto en B2: toda acción registrada se contrasta contra los datos del periodo siguiente. Alimenta "resultados de acciones anteriores" de la prioridad 3.

### Fase E — Proactividad

**E1. Motor de alertas en `wf_cron`** — `066_alertas.sql`
`alertas_evaluar()` recorre negocios activos con umbral de relevancia y cooldown por regla+objeto, devolviendo notificaciones con el mismo contrato que ya usa `mantenimiento_ciclo` (`016`). **Cero nodos nuevos**: `wf_cron` ya hace fanout a `wf_enviar`. Tabla `alertas_enviadas` para el cooldown — sin ella, Chasqui se vuelve ruido y lo silencian.

**E2. Informe periódico automático**, apoyado en B1 y B3.

### Fase F — Cartera como señal de liquidez

*Única forma en que la cartera ya construida responde la pregunta de prioridad.*
**F1.** Regla nueva en `recomendaciones_negocio`: cartera vencida con impacto (`saldo_vencido`, tipo `capital`), más liquidez como sexto frente de `salud_negocio`. **F2.** Alta manual de factura en el portal, para que quien solo carga CSV no vea la pestaña vacía. Todo lo demás de cartera sigue congelado.

---

## 6. Orden y dependencias

```
A1 (historia) ──┬──► B1 (snapshot) ──┬──► B3 (comparativas) ──► E2
A2 (inventario)─┤                    ├──► C1 ──► C2 (intenciones)
A3 (impacto) ───┤   B2 (seguimiento)─┴──► D1 ──► D3 (medir) ──► E1
A4 (router) ────┴──► todo lo que toque el router: C1, D1
A5 (limpieza + matching) ──► bloquea C
F (cartera) ──► requiere A3 (impacto_tipo)
```

A1 y A2 son los únicos verdaderamente bloqueantes. **Cada día sin A1 es historia que se pierde para siempre.**

## 7. Pruebas de aceptación

**Permanentes** (toda fase las conserva):
1. Las **ocho preguntas** de la definición de producto se responden en el chat.
2. Toda cifra entregada pasa `validar_cifras`.
3. El segundo periodo puede citar resultados del primero.

**Cuatro pruebas explícitas:**

**Historia** — Cargar 12 meses de datos bajo plan Free y verificar: (a) los 12 meses siguen **almacenados** en `movimientos`; (b) la lectura Free respeta su ventana (el informe solo usa los últimos 3 meses); (c) al pasar a un plan con histórico, los datos antiguos están disponibles **sin volver a cargarlos**.

**Inventario** — Registrar un conteo inicial, luego compras y ventas, y comprobar que el stock calculado coincide con el esperado. Además: sin conteo, el sistema identifica el resultado como **estimado** y así lo dice el informe.

**Memoria** — Ejecutar Mes 1 → recomendación, Mes 2 → acción, Mes 3 → resultado, y comprobar que Chasqui reconstruye la secuencia completa.

**Verdad** — Introducir deliberadamente una respuesta incorrecta del LLM (una cifra que no está en los hallazgos) y verificar que `validar_cifras` la detecta y la rechaza, cayendo al informe seco.

---

## 8. Plan de ejecución inmediato

**Se ejecuta A1 y solo A1. No se avanza a A2, A3, B ni ninguna otra fase sin validación previa.**

### 1. Migración
`db/migraciones/053_historia_completa.sql` — única migración de la fase. Las migraciones 001-052 **no se tocan**.

### 2. Archivos a modificar
| Archivo | Cambio |
|---|---|
| `db/migraciones/053_historia_completa.sql` | **Nuevo.** Todo el cambio de esquema y funciones |
| `docs/GUIA_FUNCIONAL.md` §10 | El plan free limita lectura, no almacenamiento |
| `docs/GUIA_TECNICA.md` | Documentar `mov_visibles` como la fuente de lectura analítica |
| `docs/PLAN_PRODUCCION.md` | Registrar el roadmap nuevo |

Ningún archivo de `bin/` ni `portal/` se modifica: el cambio es enteramente de base. (Se verifica que siga siendo cierto al terminar.)

### 3. Objetos de base de datos
**Crear**: vista `mov_visibles`.
**Reemplazar** (`CREATE OR REPLACE`, o `DROP … CASCADE` + recreación para las vistas): `movimientos_limite_plan()`; las 7 vistas de `006` (`v_costo_actual_producto`, `v_precio_actual_producto`, `v_margen_producto`, `v_deriva_costo`, `v_balance_unidades`, `v_rotacion_producto`, `v_pareto_utilidad`); `recomendaciones_negocio` y `salud_negocio` (`047`); `hallazgos_compras(bigint,jsonb)` (`043`); `hallazgos_generar(bigint)` (bloque `periodo`, `025`); `portal_movimientos_resumen`, `portal_movimientos`, `portal_documentos` (`035`); plantilla `ingesta.resumen_sesion` y `ingesta_resumen_sesion` (texto del aviso).
**Sin tocar**: `match_resolver_documento`, `ingesta_resumen_documento`, cartera, cotizador, cobro, y todo lo congelado.
**Cierre obligatorio**: `NOTIFY pgrst, 'reload schema'` (regla establecida desde la `039`).

### 4. Pruebas antes de pasar a la fase siguiente
```bash
bash bin/migrar.sh
docker compose exec postgres psql -U chasqui -d chasqui -f db/limpiar_datos.sql
```
Luego, con un negocio en plan `free`, insertar movimientos sintéticos repartidos en 12 meses y comprobar la **prueba de Historia** completa (almacenamiento, ventana de lectura, upgrade sin recarga). Después, el recorrido real de extremo a extremo:
```bash
python3 bin/gen_ventas_demo.py --cargar
docker compose exec postgres psql -U chasqui -d chasqui -c \
  "INSERT INTO ejecuciones (negocio_id, servicio_codigo, estado) VALUES (1,'ventas_compras','preparando');"
docker compose exec -e N8N_RUNNERS_BROKER_PORT=5699 n8n n8n execute --id wfEjecutar000000001
```
y verificar que el informe sigue generándose, con cifras que pasan `validar_cifras`.

### 5. Invariantes a comprobar
| # | Invariante |
|---|---|
| I1 | `count(*)` de `movimientos` **no disminuye** por efecto del plan. Ninguna ruta de escritura descarta filas (R-II) |
| I2 | Con plan free, ninguna función de análisis ve filas anteriores a `plan_desde(negocio_id)` |
| I3 | Con `plan <> 'free'`, todas las funciones de análisis ven toda la historia, sin recarga |
| I4 | `pg_depend` no deja vistas huérfanas tras el `DROP … CASCADE`: las 7 vistas y sus consumidores existen y son consultables |
| I5 | Ninguna cifra del informe cambia para un negocio cuya historia completa ya cabía en la ventana (no-regresión) |
| I6 | `validar_cifras` sigue devolviendo `ok=true` sobre el informe generado |
| I7 | Cero lógica nueva en n8n: `git diff --stat bin/ portal/` vacío al terminar la fase |
| I8 | Ninguna funcionalidad congelada tocada: `git diff` no menciona cotizador, cobro, Gotenberg ni facturación |

### 6. Evidencia para declarar A1 terminada
1. `bin/migrar.sh` aplicando `053` limpio, con su fila en `schema_migraciones`.
2. Salida de la prueba de Historia en sus tres partes, con los conteos antes/después del cambio de plan.
3. Salida de `validar_cifras` sobre el informe generado (`ok=true`).
4. `git diff --stat` mostrando solo `db/migraciones/053_*.sql` y los archivos de `docs/`.
5. Reporte corto: cambios, pruebas ejecutadas, resultados, problemas, incertidumbres restantes, y el criterio que permite continuar a A2.

**Si alguna prueba falla, la fase no se declara terminada.**

### 7bis. Cómo se verifica una fase antes de darla por cerrada

Con Postgres arriba (`docker compose up -d postgres n8n`):

```bash
bash bin/migrar.sh                    # aplica lo que falte
# … las pruebas propias de la fase …
docker compose exec -T -e PGPASSWORD="$CHASQUI_DB_PASSWORD" postgres \
  psql -U "$CHASQUI_DB_USER" -d "$CHASQUI_DB" -c \
  "INSERT INTO ejecuciones (negocio_id, servicio_codigo, estado)
   SELECT id,'ventas_compras','preparando' FROM negocios ORDER BY id LIMIT 1"
docker compose exec -e N8N_RUNNERS_BROKER_PORT=5699 n8n \
  n8n execute --id wfEjecutar000000001
```

Y después, la comprobación que importa: que el informe **no** contenga
`no pude verificar` — o sea, que no haya caído al informe seco.

```sql
SELECT id, estado, tokens_salida, (texto LIKE '%no pude verificar%') AS cayo_a_seco
FROM ejecuciones ORDER BY id DESC LIMIT 3;
```

Esa columna daba `t`. **Desde `055` da `f`** (ejecución `3`): es la prueba de
aceptación de A3, y queda como prueba permanente para las fases siguientes.

Si hace falta rehacer una migración durante su propia fase (todavía no cerrada,
todavía sin salir de la máquina), el camino es borrar su fila y reaplicar:

```sql
DELETE FROM schema_migraciones WHERE archivo = '0XX_....sql';
```

Una vez cerrada la fase, la migración es historia y solo se corrige con otra.

### 7. Forma de trabajo en las fases siguientes
Para cada fase: inspeccionar primero el código real relevante → ejecutar solo los cambios de esa fase → no tocar funcionalidades congeladas → sin refactors ajenos a la fase → correr las pruebas de aceptación → comprobar migraciones, funciones, vistas, triggers, índices y dependencias → verificar que no se reintrodujo lógica en n8n → entregar el reporte corto. Las migraciones históricas nunca se editan: todo se corrige con una migración nueva.
