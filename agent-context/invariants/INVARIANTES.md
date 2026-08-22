# Invariantes

Propiedades que deben seguir siendo verdaderas para que el sistema conserve su
comportamiento. Cada una es atómica, con evidencia y forma de verificación.

Convenciones: `status: active` en todas salvo indicación; las fuentes
normativas son las decisiones citadas — este archivo las consolida para consulta
mecánica, no las reemplaza. Si una entrada discrepa del código, manda el código:
regístralo en `../audit/discrepancies.md`.

---

```yaml
id: INV-001
domain: inteligencia
title: Ninguna cifra, umbral, regla financiera ni priorización vive en un prompt ni se deriva de la salida del modelo
evidence: [db/actual/funciones/validar_cifras.sql, db/actual/contenido/prompts.sql "TU TRABAJO ES REDACTAR, NO CALCULAR", db/actual/funciones/recomendaciones_negocio.sql]
verification: [bash bin/pruebas.sh aceptacion, db/db/pruebas/reglas_comparativas.sql]
source: CORE-001 (R-I)
```

```yaml
id: INV-002
domain: inteligencia
title: Toda cifra del informe existe en los hallazgos antes de llamar al modelo; el texto renderizado se audita contra ellos
evidence: [db/actual/funciones/validar_cifras.sql, db/actual/funciones/cifra_variantes.sql]
verification: [bin/prueba_ciclo_vida.py (camino seco = mismo validador)]
note: verifica existencia, no corrección; recombinar cifras legítimas no se detecta (RI-14)
source: CORE-001, INFORME-001
```

```yaml
id: INV-003
domain: core
title: Prohibido mover responsabilidades de SQL al LLM; la dirección permitida es la contraria
verification: revisión de decisión obligatoria antes de cualquier propuesta en sentido SQL→prompt
source: CORE-001
```

```yaml
id: INV-004
domain: datos
title: El plan limita lectura (mov_visibles) y capacidad; jamás almacenamiento. Ningún camino de escritura descarta filas por plan
evidence: [db/actual/vistas/mov_visibles.sql, db/actual/funciones/movimientos_limite_plan.sql "trigger que inserta igual y cuenta filas_fuera_de_plan"]
verification: [bash bin/pruebas.sh empty_state, E2E tercer periodo + upgrade recupera historia]
source: CORE-002 (R-II)
```

```yaml
id: INV-005
domain: recomendaciones
title: Una recomendación persiste después de la ejecución que la produjo y su resultado se mide contra ella
evidence: [db/actual/tablas/recomendaciones.sql "uq_recomendacion_abierta", db/actual/funciones/recomendaciones_medir.sql]
verification: [bash bin/pruebas.sh aceptacion "ciclo de recomendaciones"]
source: CORE-003 (R-III)
```

```yaml
id: INV-006
domain: producto
title: Toda pieza nueva aumenta conocimiento, mejora una recomendación o permite ejecutar/medir una decisión; sin esa frase no entra
verification: escribir la justificación en la decisión/migración; lista de congelados en AGENTS.md
source: CORE-004 (R-IV)
```

```yaml
id: INV-007
domain: contenido
title: Todo texto, botón, umbral, prompt, formato e intención es una fila; el mensaje final se resuelve en Postgres y n8n transporta
evidence: [db/actual/contenido/ (203 filas, 12 tablas), db/actual/funciones/resolver_plantilla.sql, bin/wf_lib.py]
verification: cambiar un texto exige migración + bash bin/gen_estado_sql.sh
source: CONTENIDO-001
```

```yaml
id: INV-008
domain: producto
title: Agregar un servicio o canal es un conjunto de INSERT; si obliga a abrir el editor de n8n, el diseño se rompió
evidence: [db/actual/tablas/servicios.sql "funcion_hallazgos", db/actual/funciones/ejecucion_preparar.sql "EXECUTE dinámico"]
source: CONTENIDO-001
```

```yaml
id: INV-009
domain: ingesta
title: Un archivo que llega siempre se guarda (bytea insertado antes de decidir si se sabe leer), en cualquier estado de la sesión
evidence: [db/actual/funciones/ingesta_registrar_documento.sql "INSERT primero, ON CONFLICT (negocio_id,hash)", db/actual/funciones/router_procesar_mensaje.sql "documento con sesión procesando ⇒ ingerir igual"]
verification: [bash bin/pruebas.sh carga_sin_perdida]
source: INGESTA-002
```

```yaml
id: INV-010
domain: ingesta
title: Pedir el análisis agenda, no arranca; la corrida la decide carga_evaluar tras carga_silencio_segundos sin archivos nuevos; un solo panel que se edita en su lugar
evidence: [db/actual/funciones/carga_evaluar.sql "pg_advisory_xact_lock", db/actual/funciones/carga_arrancar.sql "UPDATE ... WHERE estado='recibiendo' RETURNING", bin/gen_wf_ingesta.py "Esperar 11s > 10"]
verification: [bash bin/pruebas.sh carga_sin_perdida; prueba E2E espera el silencio leyendo el parámetro]
source: INGESTA-002, migraciones 075/076
```

```yaml
id: INV-011
domain: ingesta
title: El layout se identifica por huella de cabeceras; un formato ya visto no vuelve a costar tokens; el modelo puede inferir mapeo de columnas, jamás cifras
evidence: [db/actual/funciones/ingesta_huella.sql, db/actual/funciones/ingesta_identificar_tabular.sql "3 escalones", contracts/mapeo-ingesta.md]
verification: [bash bin/pruebas.sh ingesta_sin_modelo]
source: INGESTA-001
```

```yaml
id: INV-012
domain: ingesta
title: Un documento cuya fecha o valor no se reconocen va a estado error con motivo que nombra la columna; no se inserta ni una fila (nada de NULL disfrazado de éxito)
evidence: [db/actual/funciones/ingesta_cargar_tabular_detalle.sql "compuerta ≤20%"]
source: INGESTA-001
```

```yaml
id: INV-013
domain: datos
title: Toda unidad de stock declara origen (conteo/calculado/estimado); lo derivado de estimado queda marcado hasta el texto del usuario; un conteo declarado manda sobre la estimación
evidence: [db/actual/vistas/v_balance_unidades.sql "origen_stock", db/actual/funciones/salud_negocio.sql "inventario_estimado", db/actual/tablas/conteos_inventario.sql]
source: DATOS-001
```

```yaml
id: INV-014
domain: salud
title: Una nota de salud sin datos es NULL; NULL no entra al promedio ni se rellena con valor neutro; seis NULL ⇒ salud_negocio devuelve NULL (no hay semáforo)
evidence: [db/actual/funciones/salud_negocio.sql, db/pruebas/empty_state.sql "un 0 sería el fallo"]
source: HALLAZGOS-001
note: liquidez es la sexta nota y promedia, pero informe_salud_bloque sólo pinta cinco (DISC-C11)
```

```yaml
id: INV-015
domain: informe
title: El informe declara su base (archivos, movimientos vistos, fuera de plan, sin ventas); ese bloque se calcula al renderizar, NO en hallazgos
evidence: [db/actual/funciones/informe_base_bloque.sql, migración 072]
source: INFORME-001
reason: cada número dentro de los hallazgos amplía lo citable por el modelo
```

```yaml
id: INV-016
domain: informe
title: El extractor de cifras permitidas lee los números con el mismo formato con que SQL los escribió (coma decimal incluida)
evidence: [db/actual/funciones/cifra_variantes.sql, validar_cifras.sql]
source: INFORME-001 (regresión 055)
```

```yaml
id: INV-017
domain: portal
title: El rol de PostgREST no tiene permiso sobre tablas; sólo portal_* ejecutables con GRANT uno a uno; negocio_id sale del JWT; toda migración RPC termina en NOTIFY pgrst
evidence: [agent-context/reference/seguridad.md §2 "role_table_grants=0", db/actual/funciones/portal_claim.sql, agent-context/history/migraciones/033_portal.sql]
verification: catálogo (has_function_privilege); flujo manual con token
source: PORTAL-001
```

```yaml
id: INV-018
domain: router
title: El router es un despachador delgado con un handler por estado; una migración cambia sólo el handler de su estado; ninguna vuelve a copiar el router entero
evidence: [db/actual/funciones/router_procesar_mensaje.sql "delega en router_h_*", decisiones/ROUTER-001.md "historia de 8 copias y fix perdido"]
source: ROUTER-001, MIGRACION-001
```

```yaml
id: INV-019
domain: canales
title: El canal viaja en el evento normalizado (evento.canal), no en el nombre de funciones; un solo router para todos los canales
evidence: [db/actual/funciones/usuario_de_canal.sql, canal_de_chat.sql]
source: ROUTER-001, CONTENIDO-001
```

```yaml
id: INV-020
domain: planes
title: El menú se mira sin autorizar nada; el permiso se pide al elegir una opción que entrega datos y acepto:<paso> continúa ese paso; la IA se declara antes de aceptar y al pie de cada informe
evidence: [db/actual/funciones/router_h_comandos.sql "orden de bloques; re-invocación con texto original", plantilla sistema.consentimiento]
source: PLANES-001
```

```yaml
id: INV-021
domain: planes
title: Un usuario nuevo obtiene negocio automáticamente en cada mensaje entrante (usuario_de_canal); nadie queda sin poder cargar
evidence: [db/actual/funciones/usuario_de_canal.sql]
source: PLANES-001
```

```yaml
id: INV-022
domain: alertas
title: Sólo aviso prioridad alta; un aviso por negocio por corrida; cooldown por (regla, objeto); franja horaria; sólo con datos nuevos
evidence: [db/actual/funciones/alertas_evaluar.sql, db/actual/tablas/alertas_enviadas.sql, parametros alerta_*]
source: ALERTAS-001
note: "por corrida" ≠ "por día": cron corre cada 5 min (DISC RI-11)
```

```yaml
id: INV-023
domain: migraciones
title: Cambiar la firma de una función obliga a DROP de la anterior en la misma migración; una sobrecarga sobrevive sólo si tiene llamador nombrado; ninguna llamada ambigua
evidence: [bin/verificar.sh chequeo 9, db/migraciones/074_identificar_tabular_sin_ambiguedad.sql]
verification: [bash bin/verificar.sh --rapido]
source: MIGRACION-001
```

```yaml
id: INV-024
domain: baseline
title: db/base/ instala producto, nunca entorno ni lo aprendido de un cliente; rebasar se pide explícitamente (--rebasar)
evidence: [bin/gen_base.sh "filtros formatos_documento origen='semilla', portal_url_base vacía", bin/verificar.sh chequeo 8]
source: BASE-001
```

```yaml
id: INV-025
domain: repo
title: workflows/*.json, db/actual/**, db/base/** y decisiones/INDICE.md son generados: prohibido editarlos a mano
evidence: [AGENTS.md tabla generados, bin/gen_wf_*.py, bin/gen_estado_sql.sh, bin/gen_base.sh]
verification: [bash bin/verificar.sh chequeos 1 y 2]
source: AGENTS.md
```

```yaml
id: INV-026
domain: repo
title: Una migración ya aplicada no se modifica; cambio de comportamiento de producto = migración nueva (desde la 077 hoy)
evidence: [bin/verificar.sh chequeos 3 y 4]
source: AGENTS.md, MIGRACION-001
```

```yaml
id: INV-027
domain: entrega
title: Los resultados se entregan en chat y portal, nunca como PDF; lo que no cabe va al portal
evidence: [docker-compose.yml "sin Gotenberg", db/actual/funciones/informe_render.sql, portal_informes]
source: PRODUCTO-002
```

```yaml
id: INV-028
domain: producto
title: No se diseña captura manual como flujo principal; el público ya produce sus números en digital
evidence: [toda la ruta ingesta_* asume archivos exportados]
source: PRODUCTO-001
```

```yaml
id: INV-029
domain: seguridad
title: La identidad es la del canal; sin contraseñas de usuario final; el editor de n8n y Postgres no están expuestos a internet
evidence: [portal/Caddyfile "404 seco resto", docker-compose.yml puertos 127.0.0.1]
source: PORTAL-001, PLANES-001, AGENTS.md
```

```yaml
id: INV-030
domain: analisis
title: Todo análisis lee mov_visibles (ventana del plan aplicada), nunca movimientos crudos
evidence: [db/actual/vistas/mov_visibles.sql y sus consumidores en generated/dependencies.json]
warning: contar sobre movimientos da otro número (RI-4)
```
