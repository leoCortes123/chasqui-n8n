# Auditoría general de Chasqui — 2026-08-19

**Qué es este archivo.** La orden de trabajo que sale de auditar la instalación
después de la prueba de usuario del 2026-08-19. **No gobierna nada**: vale lo
mismo que el resto de `docs/` (prosa descriptiva). El registro real de cada
cambio queda en `db/migraciones/`, `decisiones/` y `decisiones/deuda.md` a
medida que cada pedido se ejecuta. Cuando los doce hallazgos estén cerrados,
este archivo se borra.

**Cómo arrancar una sesión nueva con esto.**

1. Leer `AGENTS.md` (contrato) y el resumen que imprime el hook de sesión.
2. Leer este archivo entero antes de tocar nada.
3. Confirmar el estado real: la sección "Estado de la instalación" es una foto
   del 2026-08-19 16:15 y puede haber envejecido. Los comandos para volver a
   tomarla están en "Comandos de verificación".
4. Resolver primero las cuatro **decisiones del dueño** (sección propia): cuatro
   pedidos están bloqueados hasta que se respondan.
5. Ejecutar en el orden de la sección "Orden de ejecución", no en el orden de
   severidad.

**Atajo de consulta** (verificado, no pide contraseña):

```bash
docker compose exec -T postgres psql -X -q -U postgres -d chasqui -c "SELECT 1;"
docker compose exec -T postgres psql -X -q -U postgres -d n8n     -c "SELECT 1;"
```

---

## Estado de la instalación (foto 2026-08-19 16:15)

Lo que una sesión nueva va a encontrar:

| Qué | Estado |
|---|---|
| Repo | `bin/verificar.sh --rapido` **sin violaciones** (9 chequeos) |
| Bancos | `bin/pruebas.sh` **exit 2** — 2 bancos en rojo (ver A-03) |
| Migraciones | última aplicada `076`; la próxima es la **077** |
| Negocio | id 55, un solo negocio; usuario 52, rol `operador`, chat 7815282144 |
| Sesión 1 | `expirada` 13:12:02 — 96 documentos parseados, 37.453 movimientos, `analisis_pedido_en` puesto, **análisis nunca entregado** |
| Sesión 2 | `recibiendo`, vacía, abierta desde 13:12:02 |
| `ejecuciones` | **0 filas** — no corrió ni un análisis en toda la prueba |
| n8n | 75 error · 8 success (del 16/08) · 3 canceled · 3 running |
| Canal de salida | **caído**: 30 fallas `Forbidden` de Telegram, una cada 5 min desde las 13:41 |
| `alertas_enviadas` | 37 filas, una cada 5 minutos, todas `regla=margen` |
| Respaldos | 7 de `chasqui` + 7 de `n8n`; el último 2026-08-19 12:42 |
| Árbol de git | **sucio**: `db/actual/MANIFIESTO.txt` y `db/actual/contenido/formatos_documento.sql` modificados (ver A-13) |

Las 223 ejecuciones que estaban trabadas a las 13:20 **terminaron en `error`**,
no en éxito: la cola se destrabó fallando. El análisis de los 96 archivos sigue
sin existir y los datos siguen colgando de la sesión cerrada.

Nada de esto se tocó durante la auditoría. Ver "Qué NO se hizo".

---

## Lo que se auditó y salió limpio

Para que la próxima sesión no repita el trabajo:

- Los 7 `workflows/*.json` reproducen byte a byte desde sus generadores.
- `db/actual/` refleja el catálogo vivo (160 funciones, 22 vistas, 34 tablas).
- Ninguna migración commiteada aparece modificada; numeración 074–076 completa;
  todas traen cabecera.
- 18 decisiones, referencias resueltas, 0 candidatos sin promover.
- El baseline no trae entorno ni datos de cliente (chequeo 8).
- Ninguna sobrecarga queda sin candidata única (chequeo 9, `MIGRACION-001`).
- **Portal**: el rol web no tiene privilegio sobre **ninguna** tabla; las 32
  funciones `portal_*` están concedidas una por una; `portal_claim`,
  `portal_negocio`, `portal_mov_nombre` y `portal_token_crear` no están expuestas.
  `PORTAL-001` se cumple.
- Todas las plantillas que las funciones invocan existen en `plantillas`.
- Los índices de `movimientos`, `productos`, `terceros` y `facturas` son los que
  las consultas necesitan; el problema de rendimiento (A-02) no es falta de índice.

---

## Tabla de prioridad

| # | Hallazgo | Severidad | Clasificación | Bloqueado por |
|---|---|---|---|---|
| A-12 | El bot no puede enviar mensajes desde las 13:41 | crítica | entorno | decisión D-1 |
| A-11 | Las cifras del análisis son absurdas: unidad de compra ≠ unidad de venta | crítica | decisión nueva | decisión D-2 |
| A-10 | La proactividad manda una alerta cada 5 minutos | crítica | decisión nueva | decisión D-3 |
| A-01 | El runtime se traba con una tanda de archivos | crítica | defecto | — |
| A-02 | El análisis no cabe en su presupuesto de tiempo | alta | defecto | — |
| A-03 | Los bancos están en rojo desde las migraciones de hoy | alta | defecto | — |
| A-04 | Carrera en `match_resolver_documento` mata la ingesta de un archivo | alta | defecto | — |
| A-05 | El camino de error no avisa a nadie | alta | entorno | — |
| A-06 | Una sesión cerrada abandona la carga ya subida | alta | decisión nueva | decisión D-4 |
| A-07 | Una falla permanente no aparece en el panel | media | defecto | — |
| A-08 | No existe forma de diagnosticar el runtime | media | herramienta | decisión D-5 |
| A-13 | `db/actual/` se ensucia con los formatos que el sistema aprende de un cliente | media | defecto | — |
| A-09 | Menores (WEBHOOK_URL, WhatsApp, umbral sin fila, voseo) | baja | deuda | — |

**El orden de ejecución no es el orden de severidad.** Ver la sección final.

---

## A-12 · El bot no puede enviar mensajes

```
PEDIDO 12
  Dominio:        entorno
  Clasificación:  configuración / sin causa confirmada
  Evidencia:      `fallas` id 2..31 — 30 fallas consecutivas de wf_enviar, nodo
                  EnviarTexto2, "Forbidden - perhaps check your credentials?",
                  una cada 5 minutos desde 2026-08-19 13:41:44 hasta ahora.
                  A las 13:07:40 el envío SÍ funcionaba: la sesión 1 tiene
                  panel_mensaje_id 1327, que sólo se escribe si Telegram
                  devolvió el message_id. Se rompió entre 13:07 y 13:41.
  Verificado:     el token de `.env` es válido -> getMe ok, bot @chasqui_alunabot
                  el chat existe -> getChat 7815282144 ok
                  la credencial `telegramApi` de n8n (chasquiTg0000000001) no se
                  toca desde 2026-07-24; la de DeepSeek se actualizó el 2026-08-18
  Causa:          SIN CONFIRMAR. Dos candidatas:
                  (a) el usuario bloqueó o detuvo el bot alrededor de las 13:41
                      —Telegram responde 403 a sendMessage y sigue respondiendo
                      ok a getChat, que es exactamente lo que se observa—;
                  (b) la credencial guardada en n8n es de otro bot o de un token
                      viejo, y el que funciona es el de `.env`.
                  (a) explica mejor que el envío funcionara a las 13:07 con la
                  misma credencial de julio.
  Cómo confirmar: el dueño sabe si bloqueó el bot. Si no lo bloqueó, mandar un
                  mensaje de prueba con el token de `.env` a ese chat_id
                  distingue las dos: si llega, la credencial de n8n es la vieja.
                  Es un mensaje real a una persona: no se manda sin permiso.
  Cambio:         según la causa. Si es (b), reescribir la credencial de n8n con
                  el token de `.env`.
  Migración:      ninguna — entorno
  Regenerar:      ninguno
  Verificar:      forzar una notificación y verla llegar
  R-IV:           sin canal de salida no hay producto: ningún informe, alerta ni
                  panel llega, y ninguna prueba de punta a punta significa nada
```

**Este pedido va primero.** Mientras el canal esté caído, cualquier arreglo de
los otros once es imposible de validar contra el chat real.

---

## A-11 · Las cifras del análisis son absurdas

```
PEDIDO 11
  Dominio:        datos / hallazgos
  Clasificación:  cambio de decisión — ningún invariante cubre el caso
  Decisiones:     CORE-001 — "toda cifra del informe existe en los hallazgos
                  antes de llamar al modelo" (se cumple: SQL calculó la cifra;
                  el problema es que la cifra está mal)
                  DATOS-001 — declara el origen del STOCK, no dice nada sobre la
                  equivalencia entre unidad de compra y unidad de venta
                  HALLAZGOS-001 — "toda señal que entra al semáforo sale de una
                  regla con umbral en filas"
  Evidencia:      la alerta que el cron intenta mandar cada 5 minutos dice, con
                  estas palabras: "Lo vendés a $3.500 y te cuesta $52.801: te
                  deja -1408,6% de margen" y "Son unos $9.496.278 al mes que no
                  estás ganando."
                  Producto 39, "Pasta tipo espagueti x500g", unidad 'unidad':
                    compra  4 movimientos, cantidad 2..18,
                            valor_unitario 52.042..56.138
                    venta 491 movimientos, cantidad 1..3,
                            valor_unitario 3.500
                  La compra está en cajas y la venta en paquetes. El sistema
                  divide peras por manzanas y publica el resultado.
  Causa:          no hay factor de conversión entre la unidad en que el negocio
                  COMPRA y la unidad en que VENDE. `productos.unidad` es un solo
                  campo. Ninguna regla descarta un margen imposible antes de que
                  se convierta en alerta, recomendación o informe.
  Cambio:         hace falta decidir (ver decisión D-2). Propuesta mínima:
                  1. una regla de plausibilidad: margen por debajo de un umbral
                     en filas —digamos -100%— marca el producto como
                     "costo no confiable" y lo saca de alertas, recomendaciones
                     e impacto, sin borrar el dato;
                  2. Chasqui pregunta lo que le falta: "la caja de espagueti,
                     ¿cuántos paquetes trae?". Es una pregunta que el dueño
                     contesta en dos segundos y que convierte 65 productos con
                     costo basura en 65 productos con costo real;
                  3. lo derivado de un costo no confiable se declara como tal
                     hasta el texto que lee el usuario, igual que DATOS-001 hace
                     con el stock estimado.
  Migración:      082_costo_no_confiable_no_se_publica.sql (+ la conversión, que
                  probablemente necesite su propia migración de esquema)
  Decisión nueva: DATOS-002 (relacionada_con DATOS-001, CORE-001, HALLAZGOS-001)
  Regenerar:      bash bin/gen_estado_sql.sh && python3 bin/gen_indice_decisiones.py
  Verificar:      bash bin/pruebas.sh · banco nuevo: compra por caja y venta por
                  unidad no produce alerta hasta que se declara la conversión
  R-IV:           es el corazón del producto. Un diagnóstico con cifras
                  inventadas es peor que no dar diagnóstico: se pierde al cliente
                  la primera vez que las mira
```

**Alcance real**: son 65 productos con 37.454 movimientos. Todo lo que se
calcule sobre margen, impacto en pesos, precio sugerido y priorización sale de
ahí. No es un caso raro: comprar por caja y vender por unidad es lo normal en
una tienda.

---

## A-10 · La proactividad manda una alerta cada 5 minutos

```
PEDIDO 10
  Dominio:        alertas
  Clasificación:  cambio de decisión — el invariante se cumple y aun así el
                  resultado es el que la decisión quería evitar
  Decisiones:     ALERTAS-001 — "un aviso por negocio por corrida, nunca una
                  ráfaga" · "el mismo problema no se avisa dos veces dentro del
                  cooldown" · "sólo se avisa prioridad alta"
  Evidencia:      `alertas_enviadas` tiene 37 filas entre las 13:41 y las 16:10,
                  una cada 5 minutos, todas regla 'margen', cada una de un
                  producto distinto: Harina de trigo, Kumis, Leche deslactosada,
                  Malta, Limpiador multiusos...
                  Los tres invariantes se respetan: una por corrida, ninguna
                  repetida, todas prioridad alta. El cooldown de 14 días es por
                  (regla, clave_objeto), así que con 65 productos hay 65 alertas
                  distintas esperando turno, y wf_cron da un turno cada 5 minutos.
                  Con el canal caído no llegaron. Si el canal hubiera estado
                  vivo, el dueño habría recibido 37 notificaciones en una tarde.
  Causa:          `alerta_max_por_corrida` = 1 limita por CORRIDA, y la corrida
                  ocurre cada 5 minutos. No existe límite por ventana de tiempo.
                  El invariante dice "por corrida" porque cuando se escribió, la
                  corrida y el día eran casi lo mismo.
  Cambio:         un límite por ventana, en filas (CONTENIDO-001): por ejemplo
                  `alerta_max_por_dia` por negocio, verificado contra
                  `alertas_enviadas`. Decidir el número es decisión D-3.
  Migración:      083_alertas_con_limite_por_dia.sql
  Decisión nueva: ALERTAS-002 supersede o enmienda ALERTAS-001 — el invariante
                  "un aviso por negocio por corrida" queda reemplazado por uno
                  que hable de tiempo, no de corridas
  Regenerar:      bash bin/gen_estado_sql.sh && python3 bin/gen_indice_decisiones.py
  Verificar:      bash bin/pruebas.sh · banco: 65 hallazgos altos producen N
                  avisos en un día, no 65
  R-IV:           el título de ALERTAS-001 es "un bot que avisa de más lo
                  silencian". Esto es exactamente eso, y el usuario ya bloqueó
                  el bot una vez hoy (A-12, causa candidata (a))
```

---

## A-01 · El runtime se traba con una tanda de archivos

```
PEDIDO 1
  Dominio:        ingesta
  Clasificación:  defecto
  Decisiones:     INGESTA-002 — "pedir el análisis agenda, no arranca; la corrida
                  empieza tras carga_silencio_segundos sin archivos nuevos"
  Evidencia:      sesión 1, 2026-08-19 13:07–13:12. 96 documentos parseados,
                  botón a las 13:08:01, 0 filas en `ejecuciones`.
                  A las 13:20 había 223 ejecuciones en 'running' sin avanzar,
                  n8n al 0,8% de CPU y Postgres ocioso. Tres horas después las
                  223 terminaron en 'error': la cola se destrabó fallando.
  Causa:          bin/gen_wf_router.py:141 — LlamarIngesta espera el subworkflow
                  bin/gen_wf_ingesta.py:331 — Wait de 11 s dentro de cada ingesta
                  docker-compose.yml:79 — N8N_CONCURRENCY_PRODUCTION_LIMIT=5
                  Cada archivo ocupa hasta 3 cupos (router → ingesta → enviar)
                  durante >=11 s. Con 5 cupos y 101 archivos, los cupos se llenan
                  de padres esperando hijos que ya no consiguen cupo.
  Cambio:         mover el debounce de n8n a Postgres.
                  1. nueva `carga_barrer()`: recorre las sesiones abiertas,
                     aplica la lógica de `carga_evaluar` a cada una y devuelve
                     {notificaciones, ejecuciones} con la forma que wf_cron ya
                     sabe despachar;
                  2. wf_ingesta pierde Wait/Evaluar/Decidir/PanelEnviar: guarda
                     el archivo y termina;
                  3. un scheduleTrigger de 15 s llama `carga_barrer()`. No cabe
                     en wf_cron, que corre cada 5 minutos.
                  Efecto: el análisis deja de depender de que sobreviva la
                  ejecución del último archivo.
  Migración:      079_debounce_de_carga_en_postgres.sql
  Decisión nueva: no — INGESTA-002 se cumple mejor; su invariante no cambia
  Regenerar:      python3 bin/gen_wf_ingesta.py && python3 bin/gen_wf_cron.py
                  bash bin/importar-workflows.sh && bash bin/gen_estado_sql.sh
  Verificar:      bash bin/verificar.sh · bash bin/pruebas.sh ·
                  python3 bin/prueba_ciclo_vida.py · tanda real de 100 archivos
  R-IV:           sin corrida no hay análisis: hoy 96 archivos cargados no
                  producen nada
```

Ojo al cambiar `carga_evaluar` por `carga_barrer`: el `pg_advisory_xact_lock`
por sesión de `carga_evaluar.sql:19` existe porque N ejecuciones simultáneas
mandaban N paneles. Con un solo barrido periódico el lock sigue haciendo falta
—dos barridos pueden solaparse si uno tarda— pero deja de ser la pieza crítica.

---

## A-02 · El análisis no cabe en su presupuesto de tiempo

```
PEDIDO 2
  Dominio:        core / hallazgos
  Clasificación:  defecto
  Decisiones:     CORE-002 — "el plan limita lectura y capacidad, jamás
                  almacenamiento histórico" (la ventana se respeta; el costo de
                  aplicarla es el defecto)
  Evidencia:      medido sobre el dataset real (negocio 55, 37.453 movimientos,
                  65 productos, 5 meses), dentro de BEGIN/ROLLBACK:
                    hallazgos_generar(55)   94.353 ms
                    alertas_evaluar()       28.000–37.000 ms (corre cada 5 min)
                    mov_visibles            4.291 ms  (un solo count)
                    v_rotacion_producto     7.712 ms
                    v_margen_producto       3.527 ms
                    v_pareto_utilidad       3.221 ms
                    v_deriva_costo             66 ms
                  EXECUTIONS_TIMEOUT es 300 s y al análisis todavía le falta el
                  LLM, la validación de cifras y la entrega. Un negocio con el
                  doble de historia no termina. Ya pasó una vez: la cabecera de
                  bin/gen_wf_ingesta.py:371 documenta un informe de 3.411
                  caracteres perdido por ese timeout.
  Causa:          db/actual/vistas/mov_visibles.sql — el WHERE llama
                  plan_desde(negocio_id) DOS VECES POR FILA. plan_desde es STABLE
                  pero su argumento es una columna, así que el planificador no
                  puede izarla: ~150.000 invocaciones, cada una con dos
                  subconsultas (negocios + parametro). Las cuatro vistas de
                  hallazgos se apoyan en esa vista.
  Cambio:         resolver el corte una vez por negocio:
                    FROM movimientos m
                    JOIN (SELECT id, plan_desde(id) AS desde FROM negocios) n
                      ON n.id = m.negocio_id
                    WHERE m.fecha IS NULL OR n.desde IS NULL
                       OR m.fecha >= n.desde
                  Semántica idéntica. Después volver a medir: si hallazgos_generar
                  sigue fuera de presupuesto, abrir un segundo pedido con el
                  perfil por vista.
  Migración:      078_mov_visibles_resuelve_el_plan_una_vez.sql
  Decisión nueva: no
  Regenerar:      bash bin/gen_estado_sql.sh
  Verificar:      bash bin/pruebas.sh · comparar count(*) de mov_visibles por
                  negocio antes y después · volver a cronometrar hallazgos_generar
  R-IV:           un análisis que no termina dentro del timeout no entrega nada
```

---

## A-03 · Los bancos están en rojo desde las migraciones de hoy

```
PEDIDO 3
  Dominio:        ingesta
  Clasificación:  defecto (de las pruebas, no del producto)
  Decisiones:     INGESTA-002 — "la carga entera se cuenta en un mensaje que se
                  edita en su lugar"
  Evidencia:      bash bin/pruebas.sh -> exit 2:
                    carga_sin_perdida   23|1|24
                      "silencio sin botón -> panel"  esperaba panel, dio nada
                    ingesta_sin_modelo  47|1|48
                      "cierre/4 el documento queda en error"
                                        esperaba error, dio descartado
                  Las migraciones 075 (hoy 12:30) y 076 (hoy 12:33) cambiaron los
                  dos comportamientos A PROPÓSITO —el descarte deliberado dejó de
                  ser un error, y la 076 agregó la guarda de panel en vuelo— y no
                  actualizaron los bancos.
  Causa:          db/pruebas/carga_sin_perdida.sql:125 — el fixture resetea
                  estado y analisis_pedido_en pero NO panel_pedido_en, que la
                  sección anterior dejó en now(); con panel_mensaje_id NULL, la
                  guarda de db/actual/funciones/carga_evaluar.sql:36-41 devuelve
                  'nada'. El código está bien; la expectativa quedó vieja.
                  db/pruebas/ingesta_sin_modelo.sql — 'cierre/4' sigue esperando
                  'error' donde la 075 decidió 'descartado'.
  Cambio:         actualizar las dos expectativas a lo que las 075/076
                  decidieron, citando la migración en el comentario del banco.
                  `db/pruebas/` NO es generado: se edita a mano y no es migración.
  Migración:      ninguna
  Decisión nueva: no
  Regenerar:      ninguno
  Verificar:      bash bin/pruebas.sh -> exit 0 · bash bin/verificar.sh completo
  R-IV:           con el semáforo en rojo permanente, la próxima regresión real
                  no se distingue del rojo que ya estaba
```

**Nota de método**: el hook corre `verificar.sh --rapido`, que omite el chequeo
7. El rojo vivió cuarenta minutos sin que nada lo dijera, justo durante la
prueba de usuario. Vale evaluar que el hook de fin de sesión —no el de cada
edición— corra los bancos.

---

## A-04 · Carrera en la resolución de productos

```
PEDIDO 4
  Dominio:        ingesta
  Clasificación:  defecto
  Decisiones:     INGESTA-002 — "un archivo que llega siempre se guarda"
  Evidencia:      `fallas` id 1, 2026-08-19 13:07:47, wf_ingesta nodo Resolver,
                  ejecución 3506: duplicate key value violates unique constraint
                  "uq_producto_barras".
  Causa:          db/actual/funciones/match_resolver_documento.sql:29-39 —
                  SELECT ... WHERE codigo_barras = v_codigo y, si no hay, INSERT
                  sin ON CONFLICT, contra el índice único parcial
                  uq_producto_barras (negocio_id, codigo_barras) WHERE
                  codigo_barras IS NOT NULL. Dos ejecuciones de wf_ingesta
                  procesando archivos distintos con el mismo código de barras al
                  mismo tiempo —lo normal en una tanda— pasan las dos por el
                  SELECT vacío y la segunda revienta, y se cae la resolución
                  entera de ese documento. El INSERT de `alias` de la línea 45 ya
                  tiene ON CONFLICT: es el mismo patrón resuelto seis líneas
                  más abajo.
  Cambio:         INSERT ... ON CONFLICT (negocio_id, codigo_barras)
                  WHERE codigo_barras IS NOT NULL DO NOTHING RETURNING id;
                  si RETURNING no devuelve fila, releer el id.
  Migración:      077_producto_por_barras_sin_carrera.sql
  Decisión nueva: no
  Regenerar:      bash bin/gen_estado_sql.sh
  Verificar:      bash bin/pruebas.sh · banco: dos documentos que comparten
                  código de barras resueltos en la misma transacción
  R-IV:           un archivo válido que no carga por una carrera es un dato que
                  el negocio tiene y Chasqui no
```

---

## A-05 · El camino de error no avisa a nadie

```
PEDIDO 5
  Dominio:        entorno
  Clasificación:  configuración de la instalación
  Evidencia:      31 fallas registradas en `fallas` y ningún aviso emitido.
                  select rol from usuarios -> una sola fila, 'operador'.
  Causa:          bin/gen_wf_error.py, nodo Admins:
                  WHERE rol='admin' AND telegram_chat_id IS NOT NULL
                  devuelve cero filas. wf_error registra la falla y manda el
                  aviso a nadie: todo el camino de error es un no-op.
  Cambio:         dar rol admin a un usuario con chat de Telegram.
  Migración:      ninguna — es dato de la instalación, no producto. UPDATE
                  directo, y por eso NO entra al baseline (BASE-001).
  Regenerar:      ninguno
  Verificar:      forzar una falla y ver el aviso llegar (depende de A-12)
  R-IV:           una falla que nadie ve se descubre en la siguiente prueba de
                  usuario, no antes
```

---

## A-06 · Una sesión cerrada abandona la carga ya subida

```
PEDIDO 6
  Dominio:        ingesta
  Clasificación:  cambio de decisión — ningún invariante vigente cubre el caso
  Evidencia:      13:12:02 se ejecutó /nueva o /cancelar. La sesión 1 pasó a
                  'expirada' con el análisis agendado y 96 documentos cargados;
                  la sesión 2 nació vacía. 37.453 movimientos quedaron colgando
                  de una sesión cerrada, sin forma de analizarlos. Siguen así.
  Causa:          db/actual/funciones/router_h_comandos.sql:202 y :209 — cierran
                  sin mirar si hay carga sin analizar.
                  db/actual/funciones/carga_evaluar.sql:23 — la guarda es
                  correcta; falta rescatar lo que quedó del otro lado.
  Cambio:         tres conductas defendibles (decisión D-4):
                    a) /nueva avisa y pide confirmación si hay carga sin analizar
                    b) la sesión nueva adopta los documentos huérfanos
                    c) el barrido de A-01 detecta documentos analizables sin
                       ejecución y ofrece correr el análisis
                  Recomendada: (b) + (c).
  Migración:      081_<según la opción>.sql — ROUTER-001: reemplaza sólo el
                  handler de comandos, no el router entero
  Decisión nueva: INGESTA-003 (relacionada_con INGESTA-002, CORE-002)
  Regenerar:      bash bin/gen_estado_sql.sh && python3 bin/gen_indice_decisiones.py
  Verificar:      bash bin/pruebas.sh · banco: cerrar sesión con carga pendiente
  R-IV:           datos ya cargados que no se pueden analizar son datos que el
                  usuario tiene que volver a mandar
```

---

## A-07 · Una falla permanente no aparece en el panel

```
PEDIDO 7
  Dominio:        ingesta
  Clasificación:  defecto
  Decisiones:     INGESTA-002 — "la carga entera se cuenta en un mensaje...
                  cuántos entraron, cuántos fallaron y por qué"
  Evidencia:      el panel de la sesión 1 mostró "0 fallados" con la falla
                  permanente de A-04 ya registrada.
  Causa:          db/actual/funciones/carga_resumen.sql:23-25 — `fallados` cuenta
                  documentos.estado='error'. Un archivo que revienta después del
                  INSERT del documento queda en 'pendiente' para siempre y no lo
                  cuenta nadie. `fallas` no tiene sesion_id y el errorTrigger de
                  n8n no puede saberlo, así que unir por sesión no es camino.
  Cambio:         el barrido (A-01) o mantenimiento_ciclo marca 'error' todo
                  documento 'pendiente' con más de N minutos; el panel ya sabe
                  contarlos y nombrarlos. N como parámetro en filas.
  Migración:      080_documento_pendiente_vencido_es_error.sql
  Decisión nueva: no
  Regenerar:      bash bin/gen_estado_sql.sh
  Verificar:      bash bin/pruebas.sh · banco carga_sin_perdida
  R-IV:           un archivo perdido en silencio es el fallo que INGESTA-002
                  existe para cerrar
```

---

## A-08 · No existe forma de diagnosticar el runtime

```
PEDIDO 8
  Dominio:        herramienta (bin/)
  Clasificación:  pieza nueva
  Evidencia:      los once hallazgos anteriores se encontraron consultando a
                  mano dos bases distintas. Ninguna herramienta del repo mira el
                  runtime: verificar.sh mira el repo, pruebas.sh termina en
                  ROLLBACK, prueba_ciclo_vida.py va por las rutas reales pero no
                  ve el estado de n8n. El canal de salida estuvo caído 2 horas y
                  media sin que nada lo dijera.
  Cambio:         bin/diagnostico.sh, leyendo las DOS bases directamente y nunca
                  a través de n8n —que es justo lo que se traba—:
                    runtime trabado   ejecuciones 'running' más viejas que
                                      EXECUTIONS_TIMEOUT
                    runtime muerto    ninguna ejecución nueva en N min con
                                      sesiones abiertas
                    canal caído       fallas de wf_enviar en la última hora
                    análisis colgado  sesión 'recibiendo' con analisis_pedido_en
                                      y silencio vencido, sin fila en ejecuciones
                    datos huérfanos   documentos 'parseado' de sesiones cerradas
                                      sin ejecución que los cubra
                    fallas mudas      fallas sin notificar, y
                                      usuarios WHERE rol='admin' en cero
                    ráfaga            filas de alertas_enviadas en las últimas 24 h
                    carga a medias    documentos 'pendiente' viejos
                    presupuesto       cronometrar hallazgos_generar del negocio
                                      más grande contra EXECUTIONS_TIMEOUT
  Migración:      ninguna
  Decisión nueva: RUNTIME-001, si se resuelve la tensión de la decisión D-5
  Regenerar:      ninguno
  Verificar:      correrlo contra el estado de hoy y ver que nombre A-01, A-05,
                  A-06, A-10 y A-12 sin ayuda
  R-IV:           ver decisión D-5: no pasa R-IV como pieza de producto
```

---

## A-13 · `db/actual/` se ensucia con lo que el sistema aprende de un cliente

```
PEDIDO 13
  Dominio:        base / herramientas
  Clasificación:  defecto
  Decisiones:     BASE-001 — "db/base/ no contiene ninguna fila que el sistema
                  haya aprendido de los archivos de un negocio"
                  AGENTS.md — "una tabla de producto puede tener filas que no lo
                  son —un formato que el sistema APRENDIÓ de los archivos de un
                  cliente, la URL pública del túnel de turno— y esas no entran al
                  baseline"
  Evidencia:      git status marca modificados dos generados:
                    db/actual/MANIFIESTO.txt            201 -> 203 filas
                    db/actual/contenido/formatos_documento.sql
                  Las dos filas nuevas son 'tabular_20a6271e84' y
                  'tabular_29ec2affe3', las dos con origen='inferido': son los
                  layouts que la ingesta dedujo de los archivos de la prueba de
                  hoy. Regenerado a las 16:05 del 2026-08-19.
  Causa:          bin/gen_estado_sql.sh:136 neutraliza `portal_url_base` con un
                  sed, y su propio comentario dice por qué: "sin neutralizarla,
                  cada docker compose up produce un diff en db/actual/ y el
                  chequeo 2 de bin/verificar.sh falla por un dato de entorno
                  (BASE-001)".
                  El mismo razonamiento no se aplicó a formatos_documento: las
                  filas con origen='inferido' se vuelcan tal cual. AGENTS.md
                  nombra los dos casos en la misma frase; el filtro existe para
                  uno solo.
  Consecuencia:   toda prueba de usuario con archivos nuevos ensucia el repo, y
                  `git status` deja de ser señal. El chequeo 2 pasa —db/actual/ SÍ
                  refleja el catálogo vivo— así que nada avisa. Y el chequeo 2
                  regenera db/actual/ EN EL LUGAR para comparar: auditar el repo
                  lo modifica.
  Cambio:         volcar formatos_documento filtrando origen='inferido', igual
                  que se neutraliza portal_url_base, y decir en el comentario que
                  db/actual/ es la foto del PRODUCTO, no la de la instalación.
                  Alternativa a evaluar: volcarlos a un archivo aparte que no
                  entre a git, si se quiere poder mirarlos.
  Migración:      ninguna — es el generador, no la base
  Decisión nueva: no — BASE-001 ya lo dice; falta aplicarlo
  Regenerar:      bash bin/gen_estado_sql.sh (y ver que git quede limpio)
  Verificar:      bash bin/verificar.sh · cargar un archivo con layout nuevo y
                  comprobar que db/actual/ no cambia
  R-IV:           un repo que se ensucia solo hace que el próximo agente no
                  distinga un cambio suyo de un formato aprendido ayer
```

**Qué hacer con el diff que está ahí ahora**: no se decidió nada. Las dos filas
describen la realidad de la base, así que revertirlas dejaría db/actual/
desactualizado hasta el próximo `gen_estado_sql.sh`. Si se corre
`bash bin/limpiar_negocio.sh` sin `--conservar-formatos`, los formatos
aprendidos se borran y db/actual/ vuelve solo a 201 filas.

---

## A-09 · Menores → `decisiones/deuda.md`

Ninguno rompe nada hoy. Se registran para que el próximo agente no los
"descubra" y los cambie por su cuenta.

| Qué | Por qué no se corrige ahora |
|---|---|
| `WEBHOOK_URL` vacío en `.env`; n8n arma sus URLs contra localhost | Telegram entra por el túnel y funciona; sólo afecta a las URLs que n8n genera |
| `wf_wa_router` activo con `WA_WABA_ID`, `WA_PHONE_NUMBER_ID` y `WA_ACCESS_TOKEN` vacíos | el canal no está en uso; un webhook sin credenciales falla sólo si alguien lo llama |
| `match_umbral_trgm` es un umbral sin fila: el 0.45 vive en `match_resolver_producto.sql:7` | roza CONTENIDO-001 ("un umbral se cambia con un INSERT"); `pago_enlace` está en el mismo caso y los dos tienen coalesce, así que no rompen |
| `prompts.modelo` DEFAULT `deepseek-v4-flash` contra un endpoint de Google | ya declarado en AGENTS.md; un prompt nuevo sin `modelo` explícito nace roto |
| Las plantillas usan voseo rioplatense ("lo vendés", "no estás ganando") para pymes colombianas | es contenido en filas: se cambia con un UPDATE en una migración cuando alguien lo decida |

---

## Decisiones del dueño (bloquean pedidos)

Ninguna la puede tomar un agente.

**D-1 · ¿Bloqueaste o detuviste el bot de Telegram hoy alrededor de las 13:41?**
Si sí, A-12 se resuelve desbloqueándolo. Si no, hay que mandar un mensaje de
prueba con el token de `.env` —un mensaje real a tu chat— para saber si la
credencial de n8n es la vieja. Sin esta respuesta, A-12 queda sin causa
confirmada y no se toca.

**D-2 · A-11: ¿cómo se declara la equivalencia entre unidad de compra y unidad
de venta?** Preguntándosela al dueño la primera vez que el margen da imposible;
infiriéndola del cociente entre precios; o dejando el producto marcado como
"costo no confiable" hasta que alguien la cargue por el portal. Cambia el
esquema y el flujo de conversación, así que se decide antes de escribir SQL.

**D-3 · A-10: ¿cuántos avisos por día como máximo?** Uno por día por negocio es
lo conservador; tres es lo que tolera alguien que pidió el servicio. El número
va en filas; lo que hace falta es el criterio para escribir ALERTAS-002.

**D-4 · A-06: ¿qué pasa cuando se cierra una sesión con carga sin analizar?**
Opciones (a), (b), (c) en el pedido 6. Recomendada (b)+(c).

**D-5 · A-08: ¿R-IV aplica a las herramientas de `bin/` o sólo al producto?**
Una herramienta de diagnóstico no entiende mejor el negocio ni mejora una
recomendación: como pieza de producto, no pasa R-IV. `verificar.sh` y
`pruebas.sh` tampoco lo pasarían. Si R-IV aplica sólo a producto, `diagnostico.sh`
entra sin discusión; si aplica a todo el repo, no entra y conviene escribirlo en
`decisiones/` para que nadie lo vuelva a proponer.

---

## Orden de ejecución

| Paso | Pedido | Por qué en ese lugar |
|---|---|---|
| 0 | D-1 → **A-12** | sin canal de salida nada se puede validar de punta a punta |
| 1 | **A-03** | con los bancos en rojo no se distingue una regresión nueva del rojo viejo |
| 2 | **A-04** (mig. 077) | chica, aislada, causa confirmada |
| 3 | **A-02** (mig. 078) | destraba la medición de todo lo demás; volver a cronometrar después |
| 4 | **A-01** (mig. 079) | la grande: toca dos generadores y el compose |
| 5 | **A-05** | un UPDATE; a partir de acá las fallas avisan solas |
| 6 | **A-07** (mig. 080) | se apoya en el barrido que crea A-01 |
| 7 | D-3 → **A-10** (mig. 083) | antes de volver a encender la proactividad en una prueba real |
| 8 | D-4 → **A-06** (mig. 081) | decisión INGESTA-003 primero, código después |
| 9 | D-2 → **A-11** (mig. 082) | la más grande y la que más cambia el producto |
| 10 | D-5 → **A-08** | la herramienta que evita repetir esta auditoría a mano |
| 11 | **A-13** | el generador, para que el repo deje de ensuciarse solo |
| 12 | **A-09** | escribir la deuda |

Los números de migración son los del documento: si el orden cambia, se
renumeran. Una migración por pedido, cada una con su cabecera (problema medido →
reglas → alternativas descartadas). Después de cada una: `bash bin/verificar.sh`
completo, no `--rapido`.

**A-11 al final no es que importe menos** —es lo más grave del producto— sino
que es el único que cambia esquema, conversación y decisiones a la vez, y
conviene llegar ahí con el runtime estable, los bancos en verde y el canal vivo.

---

## Comandos de verificación (reproducibles)

```bash
# repo
bash bin/verificar.sh                 # completo, incluye los bancos
bash bin/pruebas.sh                   # exit != 0 = bancos en rojo
bash bin/pruebas.sh -v carga_sin_perdida ingesta_sin_modelo

# estado de la prueba
docker compose exec -T postgres psql -X -q -U postgres -d chasqui -c "
  select id,estado,creada_en,cerrada_en,analisis_pedido_en,panel_mensaje_id
  from sesiones order by id;"
docker compose exec -T postgres psql -X -q -U postgres -d chasqui -c "
  select estado,count(*) from documentos group by 1;"
docker compose exec -T postgres psql -X -q -U postgres -d chasqui -c "
  select count(*) from ejecuciones;"
docker compose exec -T postgres psql -X -q -U postgres -d chasqui -c "
  select id,workflow,creada_en,detalle->>'nodo',left(detalle->>'mensaje',60)
  from fallas order by id desc limit 10;"
docker compose exec -T postgres psql -X -q -U postgres -d chasqui -c "
  select count(*), min(enviada_en), max(enviada_en) from alertas_enviadas;"

# runtime
docker compose exec -T postgres psql -X -q -U postgres -d n8n -c "
  select status,count(*),max(\"startedAt\") from execution_entity group by 1;"

# presupuesto de tiempo (no deja rastro)
docker compose exec -T postgres psql -X -q -U postgres -d chasqui <<'SQL'
\timing on
BEGIN;
SELECT jsonb_typeof(hallazgos_generar(55));
SELECT count(*) FROM mov_visibles WHERE negocio_id=55;
ROLLBACK;
SQL

# qué intenta mandar el cron ahora mismo (no deja rastro)
docker compose exec -T postgres psql -X -q -U postgres -d chasqui <<'SQL'
BEGIN;
SELECT jsonb_pretty(mantenimiento_ciclo() -> 'notificaciones');
ROLLBACK;
SQL
```

---

## Qué NO se hizo en esta sesión

Para que la próxima sesión sepa qué está intacto:

- **Ningún archivo del repo se modificó por la auditoría** salvo este documento.
  `db/actual/MANIFIESTO.txt` y `db/actual/contenido/formatos_documento.sql`
  aparecen modificados en `git status`: los regeneró un `gen_estado_sql.sh`
  ajeno a esta sesión a las 16:05, y su contenido son los formatos aprendidos
  en la prueba de hoy (A-13). No se revirtieron ni se commitearon.
- **Ningún cambio en la base**: todo lo que se midió corrió en `BEGIN/ROLLBACK`.
- **No se reinició nada**: las 223 ejecuciones trabadas se resolvieron solas
  fallando, no por intervención.
- **No se mandó ningún mensaje de Telegram.** Se consultaron `getMe` y `getChat`,
  que son de lectura; el mensaje de prueba que confirmaría A-12 necesita permiso.
- **No se limpió la base.** Los 96 documentos y los 37.454 movimientos de la
  prueba siguen ahí. Si se quiere empezar de cero: `bash bin/limpiar_negocio.sh`
  —y sólo eso—, pero conviene NO limpiar hasta cerrar A-11: son el único dataset
  real que expone el problema de unidades.
