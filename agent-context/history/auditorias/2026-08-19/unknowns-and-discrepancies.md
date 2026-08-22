# Discrepancias y zonas desconocidas

Nada de lo que sigue se corrigió. Es un registro.

**Relación con lo que ya estaba registrado**: `docs/auditoria_2026-08-19.md`
(A-01…A-13) es la orden de trabajo del incidente de la prueba de usuario, y
`decisiones/deuda.md` (D-001…D-010) es la deuda deliberadamente no corregida.
Este documento **no los repite**: los referencia y añade lo que esta auditoría de
ingeniería inversa encontró por su cuenta, marcado como **[NUEVO]**.

---

## 1. Contradicciones — la documentación dice X, el código hace Y

### C-1 · `README.md` describe `teclado_servicios()`, que no existe [NUEVO]
`README.md:175` («el menú se arma con `teclado_servicios()` leyendo `servicios
WHERE activo`»). Esa función **no está** en `pg_proc`. La función real es
`teclado_intake()`, que arma el menú de **módulos**, no de servicios. La propia
`docs/GUIA_TECNICA.md:320` lo dice bien: `teclado_intake` «reemplaza (057) a
`teclado_servicios`». El README quedó en la versión anterior.

### C-2 · `README.md` dice «Los 7 workflows» y lista 6 [NUEVO]
La tabla de `README.md:82` tiene `wf_router`, `wf_ingesta`, `wf_ejecutar`,
`wf_enviar`, `wf_cron`, `wf_error`. Falta `wf_wa_router`, que **existe, está
activo y tiene 2 triggers**. Y el párrafo siguiente afirma que «el 7º workflow
del plan (`wf_admin`) NO existe», lo que confunde dos cosas distintas: `wf_admin`
efectivamente no existe, pero el séptimo workflow real es el de WhatsApp.

### C-3 · `README.md` dice que la próxima migración es la 075 [NUEVO]
`README.md:23`. Las migraciones **075 y 076 ya están aplicadas** (verificado en
`schema_migraciones`). La próxima es la 077, como dice correctamente el hook de
sesión.

### C-4 · `README.md` declara 34 parámetros; hay 35 [NUEVO]
`README.md:14`. `SELECT count(*) FROM parametros` = 35. Menor, pero el mismo
párrafo se usa como descripción del baseline.

### C-5 · `docs/GUIA_TECNICA.md` no conoce el panel de carga [NUEVO]
La guía técnica (1489 líneas) menciona migraciones hasta la **070** y **no
contiene ni una vez** las palabras `carga_evaluar`, `carga_panel` ni
`descartado`. Es decir: no describe el mecanismo por el que hoy se decide si un
análisis arranca (migraciones 071/075/076) ni el estado `descartado` de un
documento. Quien la lea para entender la ingesta se llevará el modelo anterior,
que era un mensaje por archivo. Sigue siendo correcta en casi todo lo demás.

### C-6 · `docs/TELEGRAM_UX.md` lista como «fase siguiente» algo ya implementado [NUEVO]
Punto 6, «Edición de mensajes (`editMessageText`)… wizard en un solo mensaje».
Está implementado desde la migración **070** (`plantillas.reemplaza`,
`router_marcar_editables`, la rama de edición de `wf_enviar`).

### C-7 · `docs/GUIA_TRABAJO.md` declara 202 filas de contenido; hay 203 [NUEVO]
Deriva del propio A-13: `db/actual/` se ensucia con formatos aprendidos.

### C-8 · `AGENTS.md` congela el «cotizador», que está implementado entero [NUEVO]
`AGENTS.md` lista `cotizador` entre lo congelado. Existen: tabla `cotizaciones`,
4 funciones `portal_cotizacion_*` (todas concedidas al rol del portal), una
pantalla en `portal/publico/index.html` y una página pública
`portal/publico/cotizacion.html`. `[INFERIDO]` «Congelado» significa «no se
invierte más», no «no existe» — pero un lector nuevo entiende lo contrario, y la
lista de congelados es normativa.

### C-9 · La tesis «nada de reglas de negocio en los nodos» tiene excepciones vivas
Ya inventariado en `docs/historico/auditorias/2026-08.md`. **Sigue vigente**,
verificado hoy en los generadores: troceado a 3800 caracteres y elección de
plantilla por posición (`gen_wf_ejecutar.py`), detección del delimitador y
tamaños de muestra 5/100 (`gen_wf_ingesta.py`), espera literal de 11 s,
`MAX_FILAS = 6` duplicado con `parametros.teclado_max_filas`, clasificación
transitoria por regex e `INSERT` literal (`gen_wf_error.py`).

### C-10 · `CONTENIDO-001` dice que un umbral se cambia con un INSERT; dos no [NUEVO]
- `match_umbral_trgm` se lee con `parametro()` pero **no existe como fila**: el
  valor efectivo es el `coalesce(…, 0.45)` del código.
- El 5 % de la regla R2 (`precio_pagado > precio_mejor * 1.05`) está
  **hardcodeado** en el SQL, sin parámetro.
- Los 14 días mínimos de historial de R7 también.

### C-11 · `HALLAZGOS-001` dice que la liquidez es «una nota más»; el informe no la pinta [NUEVO]
`salud_negocio` calcula seis notas y **`liquidez` entra al promedio**. Pero
`informe_salud_bloque` itera sobre una lista literal de **cinco**: `ventas`,
`margenes`, `inventario`, `compras`, `riesgos`. La nota de liquidez mueve el
índice general y **nunca aparece como línea del semáforo**. Además existe la
plantilla `informe.salud_etiqueta.liquidez` y **ninguna función la lee**
(`informe_salud_bloque` no compone claves `salud_etiqueta.*`).

### C-12 · `AGENTS.md` describe `mantenimiento_ciclo` de forma incompleta
El README dice «reaper de colgadas + expiración de sesiones». Hace **cuatro**
cosas: además evalúa alertas (067) y dispara informes periódicos (068).

---

## 2. Implementación incompleta — hay infraestructura, no hay flujo

### I-1 · WhatsApp: canal completo, credenciales ausentes
`wf_wa_router` está activo con 2 triggers, `wa_texto`/`wa_payload` existen, la
descarga y el envío están generados. Pero `WA_PHONE_NUMBER_ID` está vacío, lo
que produce dos efectos simultáneos: las URLs de la Graph API quedaron sin id
(`.../v23.0//messages`) y el filtro de `phone_number_id` **se salta** porque el
código lo condiciona a que la variable no esté vacía.

### I-2 · WhatsApp no maneja la acción `panel` [NUEVO]
El `Switch` de `wf_wa_router` tiene 3 salidas. `panel` —que producen
`router_h_recibiendo` y `carga_evaluar`— cae fuera y se descarta en silencio.

### I-3 · WhatsApp duplicaría la entrega del informe [NUEVO]
`wf_wa_router` llama a `wf_ejecutar` **esperando** y después a `EnviarInforme`.
Pero `wf_ejecutar` ya entrega por su cuenta (nodo `EntregarInforme`). Además, al
esperar, toda la generación correría dentro del reloj de 300 s del router —
exactamente el bug que la rama de Telegram corrigió y documentó.

### I-4 · Ejecución de acciones: no existe
No hay ningún mecanismo que actúe sobre un sistema externo. «Aplicar precio»
escribe un hecho en `conocimiento`; `pedido_sugerido` arma una lista para mirar.
El quinto verbo del ciclo declarado en `AGENTS.md` («ejecutar») está
implementado como **registrar la decisión**, no como ejecutarla.

### I-5 · `ingesta_cargar_inventario` no es alcanzable [NUEVO]
Existe la función, existe el formato `inventario_csv` que la declara como
`funcion_parseo`, y existe la tabla `conteos_inventario`. Pero:
`ingesta_procesar_documento` corta antes por `clase='tabular'`, y `wf_ingesta`
llama siempre a `ingesta_cargar_tabular`. Además `inventario_csv` tiene
`huella = NULL`, así que `ingesta_identificar_tabular` nunca lo asigna. **No hay
forma de cargar un conteo por archivo desde el chat**; sólo por el portal.

### I-6 · `ejecuciones.costo` nunca se escribe [NUEVO]
El nodo `Cerrar` de `wf_ejecutar` sólo manda `texto`, `tokens_prompt` y
`tokens_salida`. La columna queda en su DEFAULT 0 y
`v_consumo_negocio.costo_mes` es siempre 0. El parámetro
`costo_por_1k_tokens_usd` = 0.0003 **no lo lee nadie**: su única aparición en
todo el repositorio es la fila del baseline. El control de cupo funciona porque
mide tokens, no pesos.

### I-7 · `narrado` no se persiste [NUEVO]
`wf_ejecutar` calcula si el informe fue narrado o seco y lo lleva hasta el item
final, pero `ejecucion_cerrar` no lo recibe y no hay columna. Consultando la base
no se puede saber cuántos informes salieron secos — justo la métrica que diría
si el modelo está fallando. (El usuario sí se entera: `informe_render` añade el
bloque `informe.sin_narracion`.)

### I-8 · `cuadra` de una factura DIAN se calcula y se tira [NUEVO]
`ingesta_parsear_dian` compara `suma_lineas + impuesto` contra `PayableAmount`
con tolerancia < 1 y devuelve `cuadra: true|false`. Ese valor viaja hasta el nodo
`Procesar` de n8n y muere ahí. Ninguna factura se rechaza ni se marca por no
cuadrar.

### I-9 · `negocios.nit` vacío inhabilita dos funcionalidades enteras [NUEVO]
`cartera_facturar_dian` decide venta/compra comparando `negocios.nit` con el
emisor. Con `nit` NULL —el estado actual— **toda** factura entra como compra.
Consecuencias en cadena: no hay facturas `tipo='venta'`, la nota de liquidez del
semáforo es siempre `NULL`, y la regla R11 `cartera` es inalcanzable. Existe
`portal_negocio_guardar(p_nit)` y las plantillas tienen la variable `aviso_nit`,
pero nada obliga a llenarlo.

### I-10 · `snapshots_backfill()` no la llama nadie
Deuda D-006. Sin llamador, los snapshots parciales que la regla `margen_cae`
sabe distinguir (`metricas->>'parcial'`) nunca se producen.

### I-11 · No hay usuario `admin` en esta instalación [NUEVO]
`wf_error` avisa a `usuarios WHERE rol='admin'`. El único usuario es `operador`.
Las 51 fallas registradas hoy **no avisaron a nadie**. Es A-05, confirmado.

### I-12 · `parametros.pago_enlace` no existe como fila [NUEVO]
`router_plan` pinta un enlace de pago si `parametro(negocio,'pago_enlace')` tiene
valor. No hay ninguna fila con esa clave, para ningún negocio. El código de cobro
está, el dato no.

---

## 3. Código muerto o sin ruta activa

`[CONFIRMADO]` por búsqueda exhaustiva en `db/actual/`, `bin/`, `workflows/` y
`portal/`.

### Plantillas sin ningún lector [NUEVO]
Once claves de `plantillas` no aparecen en ninguna función, generador ni
workflow, y no se componen dinámicamente:

```
ejecucion.en_curso            (existe ejecucion.ya_en_curso, que sí se usa)
ingesta.error_archivo         ingesta.error_descarga
ingesta.error_guardando       ingesta.error_no_soportado
ingesta.esperando_mas         ingesta.formato_nuevo
ingesta.ok                    ingesta.parcial
ingesta.pedir_columnas        ingesta.todos_archivos
```

Las diez `ingesta.*` son los mensajes por archivo que la migración **071**
reemplazó por el panel. `[INFERIDO]` Quedaron huérfanas y nadie las dio de baja.
A ellas hay que sumar `ingesta.resumen_sesion`: su única aparición en todo el
repositorio es su propio `INSERT` del baseline, y la función de nombre parecido
(`ingesta_resumen_sesion`) ni la nombra ni tiene llamador (D-006). Son **doce**
plantillas huérfanas en total.

**No están muertas** (se componen dinámicamente y por eso no aparecen en un
grep): `ejecucion.entregada.consulta` (`'ejecucion.entregada.'||servicio` en
`ejecucion_cerrar`), `informe.encabezado.consulta`, `informe.pie.consulta`,
`informe.titular_seco.consulta`, `informe.titular_seco.mercado_compras`
(`plantilla_cuerpo_srv` añade `'.'||servicio`).
**Sí está muerta**: `informe.salud_etiqueta.liquidez` — ninguna función compone
esa familia de claves.

### Funciones sin llamador
Deuda D-006, revalidada: `ingesta_cargar_inventario`, `ingesta_resumen_sesion`,
`plantilla_cuerpo`, `snapshots_backfill`, `usuario_de_telegram`.
(`ingesta_parsear_dian` **sí** tiene llamador: `ingesta_procesar_documento`, y
además los scripts de datos de prueba.)

### Valores de enum sin escritor [NUEVO]
- `estado_ejec.validando` — nadie lo escribe; sólo aparece en los `WHERE … IN`
  del reaper y del índice `idx_ejec_colgadas`.
- `tipo_movimiento.ajuste` — nadie lo escribe. `portal_movimientos` lo acepta
  como filtro.
- `rol_usuario.dueno` — sólo lo escriben bancos de prueba y
  `bin/cargar_datos_prueba.py`; **nadie lo lee**. El único rol con efecto es
  `admin`.

### Columnas sin escritor [NUEVO]
- `documentos.motivo_pendiente` — declarada en el esquema, ninguna función la
  escribe ni la lee.
- `ejecuciones.pdf` — `ejecucion_cerrar` la preserva pero nadie la llena
  (Gotenberg fuera).
- `ejecuciones.costo` — ver I-6.

### Rama de workflow sin llamador [NUEVO]
La rama «documento» de `wf_enviar` (`HayDoc?` → `PrepDoc` → `EnviarDoc` /
`WaSubirDoc` → `WaMandarDoc`) exige que alguna respuesta traiga
`r.documento` **y** que llegue un binario. Ninguna función SQL emite
`respuestas[].documento`. Es el resto del camino del PDF.

---

## 4. Duplicaciones

### DUP-1 · Dos modelos de identidad conviviendo
`usuarios.telegram_user_id / telegram_chat_id / telegram_username` (modelo
anterior) y `identidades(canal, id_externo, datos)` (modelo actual).
`usuario_de_canal` escribe en **los dos**. `chat_de_usuario` y `carga_panel`
leen `identidades` primero y caen a `usuarios`. `v_negocios_alertables` y
`v_negocios_informe_periodico` leen **sólo** `usuarios.telegram_chat_id`
`[NUEVO]`: un usuario que entrara únicamente por WhatsApp **nunca recibiría una
alerta ni un informe periódico**.

### DUP-2 · Dos identidades de proveedor
`movimientos.raw->>'proveedor'` (texto libre, es lo que usan **todas** las
reglas) y `terceros` + `movimientos.tercero_id` (sólo lo llena la ruta DIAN, es
lo que usa la cartera). No hay conciliación entre ambos.

### DUP-3 · El tope de teclado en dos sitios
`parametros.teclado_max_filas` = 6 y `MAX_FILAS = 6` en `bin/gen_wf_enviar.py`.
Cambiar la fila sin regenerar produce teclados que el enviador no sabe expresar.

### DUP-4 · Dos funciones que persisten un formato aprendido
`ingesta_registrar_formato_resuelto` (por diccionario, sin modelo) e
`ingesta_registrar_formato_inferido` (con modelo). **Las dos escriben
`origen = 'inferido'`** `[NUEVO]`. Sólo se distinguen por el `nombre` («Tabla
reconocida/agregada» vs «Tabla inferida»). Consultar `formatos_documento.origen`
no dice si costó una llamada al modelo.

### DUP-5 · Dos relojes de «hoy»
`v_hasta = max(fecha)` en R7/R8/R10 y en `intencion_resolver`; `current_date` en
R11, `plan_desde`, `conocimiento_buscar`. Ambas elecciones están justificadas en
comentarios, pero conviven en el mismo informe.

### DUP-6 · Sobrecargas deliberadas
`hallazgos_generar` y `hallazgos_compras` tienen firma de 1 y de 2 argumentos.
Es **intencional**: `ejecucion_preparar` despacha con `(bigint, jsonb)` y la de
dos argumentos es un envoltorio. `bin/verificar.sh` chequeo 9 comprueba que no
produzcan ambigüedad.

---

## 5. Ambigüedades — no se puede determinar cuál es la implementación canónica

### AMB-1 · `cupo_tokens_mes = 0` significa dos cosas opuestas [NUEVO]
`ejecucion_preparar` bloquea sólo si `cupo > 0 AND usados >= cupo`: con
`cupo = 0` **nunca bloquea**. `router_plan` interpreta `cupo = 0` como
«⛔ El servicio está suspendido para tu negocio». Las dos lecturas están en el
código y son incompatibles. `[NO DETERMINADO]` cuál es la intención.

### AMB-2 · ¿`db/actual/contenido/` es producto o es foto?
`bin/gen_estado_sql.sh` lo genera desde la base viva, así que mezcla producto
(entra por migración) con lo que el sistema aprendió de un cliente (`origen =
'inferido'`). El chequeo 8 de `verificar.sh` protege `db/base/` pero no
`db/actual/`. Es A-13; sin resolver.

### AMB-3 · ¿Dónde vive el nombre del modelo?
Deuda D-007. Hoy: entorno horneado en filas de producto, con el DEFAULT de la
columna apuntando a un modelo que el proxy configurado no tiene.

### AMB-4 · ¿Qué es «una sesión» para la carga? [NUEVO]
`carga_hay_con_que` mira los `documentos` **de esa sesión**… salvo para
`mercado_compras`, donde mira si el negocio tiene alguna compra visible. Dos
semánticas distintas de «tengo con qué» según el servicio.

### AMB-5 · ¿Qué pasa con `mercado_compras` y las recomendaciones? [NUEVO]
Su `funcion_hallazgos` no produce recomendaciones, pero `ejecucion_cerrar`
—que sólo mira `entrada='archivos'`— llama igual a `recomendaciones_registrar`,
que ejecuta las reglas de **ventas**. Una corrida de «Mercado de compras»
registra recomendaciones que su propio informe nunca mostró.

### AMB-6 · El prompt de `mercado_compras` describe un producto distinto [NUEVO]
Empieza con «Partí de la lista `recomendaciones`», que en ese servicio **siempre
viene vacía**. La rama de fallback («si viene vacía, usá `deriva_costo`,
`precio_disperso`, `proveedores`, `sin_venta`») es la única que se ejecuta.
`[INFERIDO]` El prompt se copió del de `ventas_compras` sin ajustar.

---

## 6. Riesgos de interpretación para alguien nuevo

| # | Trampa | Por qué |
|---|---|---|
| RI-1 | Leer `db/migraciones/` para saber cómo funciona algo | Sólo hay 3 archivos (074-076). El estado está en `db/actual/`. Las 73 que construyeron el sistema están en `docs/historico/migraciones/` y **no gobiernan** |
| RI-2 | Editar `workflows/*.json` | Son generados. Se cambia `bin/gen_wf_*.py`. `verificar.sh` chequeo 1 detecta la edición |
| RI-3 | Leer `workflows/fotos/*.json` | Exportaciones de n8n para reconstruir tras perder el volumen. **No son fuente de nada** y pueden estar desfasadas |
| RI-4 | Consultar `movimientos` directamente | Todo el análisis lee `mov_visibles`, que ya filtró por plan. Contar sobre `movimientos` da otro número |
| RI-5 | Creer que `formatos_documento.origen='inferido'` significa «lo hizo el modelo» | También lo escribe el camino del diccionario, que no gasta tokens (DUP-4) |
| RI-6 | Creer que `salud_negocio` tiene cinco notas | Tiene seis; `liquidez` promedia pero no se pinta (C-11) |
| RI-7 | Creer que el proveedor es una entidad | Para las reglas es `raw->>'proveedor'`, texto libre. Dos grafías = dos proveedores |
| RI-8 | Creer que `recomendaciones_negocio` devuelve lo que ve el usuario | Devuelve el top 8 con `p_registro=false`; con `true` devuelve **todo** (123 hoy). `alertas_evaluar` usa el modo `true` |
| RI-9 | Creer que un informe exitoso deja rastro en n8n | `EXECUTIONS_DATA_SAVE_ON_SUCCESS=none`. Sólo se guardan errores, 7 días |
| RI-10 | Creer que `parametros` con `negocio_id` NULL es «sin negocio» | Es el valor **global**; `parametro()` prefiere el del negocio y cae al global |
| RI-11 | Creer que `alerta_max_por_corrida = 1` limita las alertas del día | Limita por **corrida**, y hay una corrida cada 5 minutos (A-10) |
| RI-12 | Creer que las 11 reglas comparten umbral de prioridad | Cada `impacto_tipo` tiene su propia vara, y `dependencia` está excluida por nombre |
| RI-13 | Creer que `bin/verificar.sh` es sólo lectura | Su chequeo 2 corre `gen_estado_sql.sh` y **regenera `db/actual/`** |
| RI-14 | Creer que `validar_cifras` verifica que la cifra sea la correcta | Verifica que **exista** en el JSON de hallazgos. El modelo puede citar una cifra real del producto equivocado |
| RI-15 | Creer que el LLM elige qué recomendar | La detección, el impacto, la prioridad y el orden los calcula SQL. El modelo redacta |
| RI-16 | Creer que `db/base/000_esquema.sql` describe el esquema actual | Está congelado en v0. La 075 añadió `descartado` a `estado_doc` y el baseline sigue diciendo tres valores (D-010) |

---

## 7. Zonas que esta auditoría NO pudo determinar

| # | Pregunta | Qué evidencia falta |
|---|---|---|
| ND-1 | ¿Se completó alguna vez un análisis en esta instalación? | `ejecuciones` tiene 0 filas y n8n no guarda ejecuciones exitosas. No hay forma de saberlo desde la base |
| ND-2 | ¿Por qué Telegram devuelve `Forbidden`? | `fallas` guarda el mensaje, no el cuerpo de la respuesta. Habría que consultar `getMe`/`getChat` contra la API. Causa candidata registrada en A-12 |
| ND-3 | ¿Cuánto tarda de verdad `wf_ejecutar` de punta a punta? | Nunca se completó una ejecución. Sólo se midieron las llamadas SQL por separado (95,6 s de preparación) |
| ND-4 | ¿El informe narrado pasa `validar_cifras` con el modelo actual? | Exige gastar tokens (`prueba_ciclo_vida.py --con-llm`). No se ejecutó en esta auditoría |
| ND-5 | ¿Los workflows desplegados en n8n son idénticos a los del repo? | Se comparó el **número de nodos** (coincide en los 7) y `verificar.sh` chequeo 1 confirma que los JSON reproducen desde los generadores. No se hizo un diff nodo a nodo del contenido desplegado |
| ND-6 | ¿Funciona el portal de punta a punta? | Requiere un token vivo y un navegador. No se probó |
| ND-7 | ¿Qué produce WhatsApp con credenciales reales? | Sin credenciales de Meta |
| ND-8 | ¿Por qué el escenario `datos_incompletos` no dispara `agota` ni `cartera`? | Deuda D-009, abierta: no se sabe si miente el generador o el contrato del banco |
| ND-9 | ¿Cuál es la intención con `cupo_tokens_mes = 0`? | Dos lecturas incompatibles en el código, ninguna decisión escrita (AMB-1) |
| ND-10 | ¿La huella de cabeceras colisiona en la práctica? | `ingesta_huella` es `md5` sobre las cabeceras **normalizadas, deduplicadas y ordenadas alfabéticamente`. Dos layouts con las mismas columnas en distinto orden comparten huella **a propósito**; si además tuvieran distinto formato de fecha, el segundo se cargaría con el mapeo del primero. No hay caso observado |

---

## 8. Observaciones que no son defectos, pero conviene saber

- **`router_h_comandos` tiene 251 líneas y 13 ramas.** `ROUTER-001` separó los
  handlers por estado; lo que no depende del estado se acumuló todo aquí.
- **`recomendaciones_negocio` tiene 683 líneas.** Cada regla nueva la alarga.
  Su tiempo de ejecución medido es 47,2 s con 65 productos.
- **`hallazgos_comparativo` llama otra vez a `salud_negocio`.** No hay memoización;
  `hallazgos_generar` paga la nota de salud dos veces (26,9 s cada una).
- **`match_resolver_documento` recorre fila por fila** con un bucle `FOR`, no en
  conjunto. Con 37.454 movimientos eso son 37.454 iteraciones de plpgsql.
- **La salida de `admin_reporte` lleva asteriscos de Markdown** pero se envía con
  `parse_mode: HTML`, así que el admin ve los asteriscos literales. Sin impacto.
- **`fallas` y `alertas_enviadas` no tienen poda.** Crecen indefinidamente.
- **El secreto del webhook de Telegram está en un JSON versionado.** Es una
  consecuencia del diseño de los generadores, no un descuido.
