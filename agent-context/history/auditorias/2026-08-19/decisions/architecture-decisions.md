# Decisiones arquitectónicas observadas

**No son ADRs inventados.** Son decisiones que el código, las migraciones y la
configuración demuestran que se tomaron. Para cada una: evidencia, motivación
**sólo si es determinable**, consecuencias y nivel de certeza.

`decisiones/` (18 decisiones vigentes) es la fuente normativa del proyecto. Este
documento **no la reemplaza**: es la lectura desde el código, e indica en cada
caso si la decisión ya está escrita allí o si sólo vive en la implementación.

---

## D-A · PostgreSQL como sistema completo, no como almacenamiento

```
Decisión observada  Postgres contiene el esquema, los datos, los archivos
                    originales (bytea), la máquina de estados, los textos, los
                    botones, los umbrales, los prompts, el layout del informe y
                    las reglas de negocio. n8n sólo transporta.
Evidencia           160 funciones y 22 vistas en un solo schema. 203 filas en 12
                    tablas de contenido. documentos.contenido guarda el archivo.
                    router_procesar_mensaje es la máquina de estados completa.
                    informe_render (235 líneas) es el motor de layout.
Motivación conocida AGENTS.md la declara y la argumenta: "si para lanzar un
                    servicio nuevo hay que abrir el editor de n8n, el diseño se
                    rompió". Decisión escrita: CONTENIDO-001.
Consecuencias       + agregar un servicio es un conjunto de INSERT
                    + todo el comportamiento es versionable por migración
                    - el rendimiento del producto es el rendimiento de una
                      consulta SQL: 95,6 s medidos para hallazgos_generar
                    - depurar exige leer plpgsql, no un lenguaje de aplicación
                    - no hay capa donde poner cache
Certeza             ALTA · confirmada por código y por decisión escrita
```

## D-B · n8n como runtime fijo de 7 workflows

```
Decisión observada  Los workflows son ARTEFACTOS GENERADOS por scripts Python.
                    Editarlos a mano es una violación detectable.
Evidencia           bin/gen_wf_*.py + bin/wf_lib.py; bin/verificar.sh chequeo 1
                    los reproduce byte a byte; AGENTS.md los lista como
                    "Generado — nunca editar a mano".
Motivación conocida No determinada en su origen; el efecto buscado sí está
                    escrito: que el comportamiento no viva en nodos.
Consecuencias       + un workflow perdido se reconstruye desde el generador
                    + los comentarios de los generadores conservan el PORQUÉ de
                      cada nodo, con los bugs que lo motivaron
                    - los secretos quedan horneados en JSON versionados
                    - cambiar una constante de nodo exige regenerar e importar
                    - la lógica que SÍ quedó en nodos (troceado, delimitador,
                      clasificación de errores) es invisible desde SQL
Certeza             ALTA
```

## D-C · El LLM interpreta y redacta; nunca calcula

```
Decisión observada  Toda cifra existe en los hallazgos ANTES de llamar al modelo,
                    y el texto renderizado se audita contra esos hallazgos.
Evidencia           validar_cifras(); prompts.sistema id 4: "TU TRABAJO ES
                    REDACTAR, NO CALCULAR"; informe_render pone el layout;
                    recomendaciones_negocio calcula impacto, precio sugerido,
                    unidades a pedir y proveedor más barato.
Motivación conocida CORE-001 e INFORME-001. El corolario está escrito: "está
                    prohibido mover al LLM responsabilidades que hoy son de SQL;
                    la dirección permitida es la contraria".
Consecuencias       + el informe no puede inventar una cifra
                    + funciona sin el modelo (informe seco)
                    - toda regla nueva es SQL, y el SQL ya pesa 683 líneas en
                      una sola función
                    - el modelo puede recombinar cifras legítimas y el validador
                      no lo detecta
Certeza             ALTA
```

## D-D · Los datos nunca se destruyen por el plan

```
Decisión observada  El plan limita LECTURA, no almacenamiento.
Evidencia           trigger movimientos_limite_plan devuelve NEW SIEMPRE; sólo
                    incrementa documentos.filas_fuera_de_plan.
                    plan_desde() + vista mov_visibles hacen el filtro de lectura.
                    Todo el análisis lee mov_visibles, nunca movimientos.
Motivación conocida CORE-002: "un upgrade de plan debe recuperar el pasado sin
                    que el cliente vuelva a subir nada".
Consecuencias       + el upgrade es instantáneo y gratis
                    - la base crece sin techo para clientes que no pagan
                    - reglas que necesitan 13 meses (vs_ano_anterior) son
                      inalcanzables en plan free, aunque los datos estén ahí
Certeza             ALTA
```

## D-E · Una recomendación es una entidad, no una línea de informe

```
Decisión observada  Las recomendaciones persisten, se refrescan, se cierran con
                    causa y se miden contra la métrica que las originó.
Evidencia           tabla recomendaciones (23 columnas); recomendaciones_registrar
                    con sus 4 pasos; recomendacion_marcar_cierre graba
                    valor_al_cerrar; recomendaciones_medir; tabla de contenido
                    metricas_resultado con métrica, dirección y umbral por regla.
                    La distinción detectado/mostrado (en_informe) existe para no
                    cerrar por error lo que sólo quedó fuera del top 8.
Motivación conocida CORE-003. La migración 059 explica el problema medido.
Consecuencias       + se puede responder "¿sirvió lo que te dije?"
                    + el informe puede decir "van cuatro veces que te lo digo"
                    - la identidad de una recomendación es (regla, clave_objeto),
                      y clave_objeto es un string compuesto sin FK
                    - metricas_resultado no tiene FK: una regla nueva sin su fila
                      nunca se mide, en silencio
Certeza             ALTA
```

## D-F · El stock declara su origen

```
Decisión observada  Todo stock dice si salió de un conteo, de un cálculo sobre un
                    conteo, o de una estimación, y eso viaja hasta el texto.
Evidencia           v_balance_unidades.origen_stock; v_rotacion_producto lo
                    propaga; salud_negocio devuelve inventario_estimado;
                    informe_salud_bloque pinta un asterisco y una nota al pie;
                    r_agota y r_quieto lo dicen en el texto del problema;
                    pedido_sugerido marca stock_estimado por ítem.
Motivación conocida DATOS-001: "un conteo declarado por el dueño manda sobre la
                    estimación".
Consecuencias       + no se presenta una estimación como dato
                    - la misma disciplina NO se aplicó al costo: no hay
                      "costo no confiable" y el margen absurdo se publica igual
Certeza             ALTA para stock; la ausencia en costo es el hallazgo A-11
```

## D-G · Un solo hostname público y el editor fuera de internet

```
Decisión observada  Caddy es el único puerto publicado; n8n y Postgres sólo en
                    loopback; sólo pasan /webhook, /api y /portal.
Evidencia           docker-compose.yml (127.0.0.1:*); portal/Caddyfile con
                    handle{ respond 404 } como default.
Motivación conocida El comentario del compose lo dice: "antes el túnel apuntaba
                    directo a n8n y el editor quedaba expuesto".
Consecuencias       + el editor de n8n no es alcanzable desde fuera
                    + el portal sale por el mismo hostname que el webhook
                    - un solo punto de fallo para las tres superficies
Certeza             ALTA
```

## D-H · El portal es PostgREST sin backend, con GRANT por función

```
Decisión observada  El rol web no tiene privilegio sobre NINGUNA tabla; lo único
                    ejecutable son funciones portal_* concedidas una por una; el
                    negocio sale del JWT.
Evidencia           role_table_grants para portal_anon/portal_usuario: 0 filas.
                    28 funciones SECURITY DEFINER con GRANT explícito.
                    portal_claim lee request.jwt.claims.
                    PGRST_OPENAPI_MODE=disabled.
Motivación conocida PORTAL-001, con sus 4 invariantes.
Consecuencias       + no hay una línea de backend que mantener
                    + una tabla nueva NO queda expuesta por accidente
                    - cada consulta del portal es una función más en la base
                    - PostgREST impone la forma: todo es POST /rpc/<funcion>
Certeza             ALTA
```

## D-I · La identidad es el canal de mensajería

```
Decisión observada  No hay registro, no hay contraseñas. El usuario y su negocio
                    se crean solos al primer mensaje. El acceso al portal es un
                    enlace de un solo uso desde el chat.
Evidencia           usuario_de_canal crea usuario + identidad + negocio;
                    portal_token_crear/portal_sesion_abrir; PLANES-001
                    invariante "un usuario nuevo recibe su negocio
                    automáticamente".
Consecuencias       + fricción cero para empezar
                    - no hay forma de que dos personas compartan un negocio
                      salvo asignándoles el mismo negocio_id a mano
                    - perder la cuenta de Telegram es perder el acceso
                    - el JWT del portal vive 12 h sin revocación posible
Certeza             ALTA
```

## D-J · El permiso se pide donde se entienden sus consecuencias

```
Decisión observada  El menú se mira sin autorizar nada; el consentimiento se pide
                    al elegir una opción que entrega datos, y al aceptar el
                    proceso continúa donde estaba.
Evidencia           router_h_comandos: los handlers de 'mod'/'modayuda' están
                    ANTES del bloque de consentimiento, con comentario explícito.
                    El botón manda 'acepto:<mensaje original>' y el router se
                    re-invoca con ese texto.
Motivación conocida PLANES-001.
Consecuencias       + el usuario no autoriza a ciegas ni pierde el paso
                    - hay una recursión controlada en router_procesar_mensaje
Certeza             ALTA
```

## D-K · Chasqui habla primero, con freno

```
Decisión observada  Hay proactividad (alertas e informes periódicos) y hay
                    guardarraíles en filas: prioridad alta únicamente, cooldown,
                    franja horaria, tope por corrida, y exigir dato nuevo.
Evidencia           alertas_evaluar + parametros alerta_*; v_negocios_alertables
                    exige ultimo_dato > ultimo_analisis.
Motivación conocida ALERTAS-001, cuyo título es "un bot que avisa de más lo
                    silencian".
Consecuencias       + los cuatro invariantes se cumplen literalmente
                    - EL RESULTADO ES EL QUE LA DECISIÓN QUERÍA EVITAR: el tope
                      es por corrida y la corrida ocurre cada 5 minutos.
                      57 alertas registradas en una tarde.
Certeza             ALTA para la decisión; el defecto está confirmado y es A-10
```

## D-L · El informe se entrega en el chat, nunca como archivo

```
Decisión observada  El informe es texto de Telegram troceado; lo que no cabe va
                    al portal. Gotenberg salió del compose.
Evidencia           PRODUCTO-002; docker-compose.yml sin Gotenberg;
                    ejecuciones.pdf existe y queda siempre en NULL;
                    RespFinal trocea a 3800 caracteres.
Motivación conocida PRODUCTO-002.
Consecuencias       + no hay dependencia de un renderizador
                    - el informe compite con el límite de 4096 de Telegram
                    - queda una columna bytea muerta y una rama de wf_enviar
                      (envío de documento) sin llamador
Certeza             ALTA
```

## D-M · El baseline como instalación, y las 73 migraciones archivadas

```
Decisión observada  db/base/ es Chasqui v0 (esquema + contenido, sellando las 73);
                    db/migraciones/ arranca en la 074; db/actual/ es la foto
                    generada del catálogo vivo.
Evidencia           bin/migrar.sh instala db/base/ si la base está vacía;
                    schema_migraciones tiene 76 filas, 73 con la misma marca de
                    tiempo (el sellado); docs/historico/migraciones/ tiene las 73.
Motivación conocida AGENTS.md la explica con números: 23.833 líneas, 263
                    definiciones para 163 nombres, router_procesar_mensaje
                    redefinida 15 veces, y un fix perdido.
Consecuencias       + "cómo funciona algo hoy" tiene una sola respuesta
                    - el baseline puede envejecer respecto de la base viva
                      (deuda D-010: los enums)
                    - db/actual/ se ensucia con lo que el sistema aprende
                      (A-13)
Certeza             ALTA
```

## D-N · Un handler por estado, y ninguna migración copia el router entero

```
Decisión observada  El router es un despachador delgado con 5 handlers.
Evidencia           router_procesar_mensaje (60 líneas) + router_h_*;
                    ROUTER-001.
Consecuencias       + una migración que cambia un estado toca un solo handler
                    - router_h_comandos acumuló 251 líneas y 13 ramas: es el
                      handler que concentra todo lo que no depende del estado
Certeza             ALTA
```

## D-O · Dos canales, un solo cerebro

```
Decisión observada  El canal viaja en el evento normalizado; el router es uno.
Evidencia           usuario_de_canal(canal, evento); canal_de_chat;
                    wf_wa_router llama al MISMO router_procesar_mensaje;
                    wa_texto/wa_payload traducen en SQL, no en nodos.
Motivación conocida ROUTER-001 invariante 3.
Consecuencias       + agregar un canal es un workflow de transporte
                    - el canal nuevo puede DIVERGIR sin que nada lo detecte:
                      wf_wa_router no maneja la acción 'panel' y duplica la
                      entrega del informe (ver interfaces/n8n.md)
Certeza             ALTA para la decisión; las divergencias están confirmadas
```

## D-P · El conocimiento del proyecto vive en el repositorio

```
Decisión observada  decisiones/ es normativo, db/actual/ es descriptivo,
                    docs/historico/ no gobierna; dos servidores MCP separados
                    responden "cómo debe ser" y "cómo está"; hooks de sesión y
                    de guardia; verificar.sh como juez.
Evidencia           AGENTS.md; .mcp.json; bin/mcp_decisiones.py;
                    bin/hook_sesion.sh; bin/hook_guardia.sh;
                    decisiones/deuda.md con 10 entradas.
Motivación conocida AGENTS.md: "las reglas importantes no pueden depender de que
                    un agente las recuerde".
Consecuencias       + un agente nuevo llega con contrato, no con intuición
                    + la deuda está registrada en vez de corregida a escondidas
                    - es una capa de proceso que hay que mantener al día
Certeza             ALTA
```

---

## Decisiones NO tomadas (ausencias con consecuencia)

`[INFERIDO]` No son omisiones descuidadas: son huecos que el código demuestra y
que ninguna decisión escrita cubre.

| Ausencia | Consecuencia observable |
|---|---|
| No hay decisión sobre **unidad de compra vs. unidad de venta** | A-11: márgenes de −1408 %, impactos de millones, 57 alertas sobre un cálculo imposible |
| No hay decisión sobre **dónde vive el nombre del modelo** | deuda D-007: entorno horneado en una fila de producto; el DEFAULT apunta a un modelo inexistente |
| No hay decisión sobre **presupuesto de tiempo del análisis** | A-02: 95,6 s sólo para preparar, contra un techo de 300 s |
| No hay decisión sobre **qué pasa con los documentos de una sesión cerrada** | A-06: 96 documentos colgando de una sesión expirada |
| No hay decisión sobre **límite de alertas por unidad de tiempo** | A-10 |
| No hay decisión sobre **observabilidad del runtime** | A-08: no hay forma de diagnosticar n8n desde la base |
| No hay decisión sobre **retención de `fallas` y `alertas_enviadas`** | crecen sin poda |
