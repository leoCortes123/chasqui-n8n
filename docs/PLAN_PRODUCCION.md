# Plan de salida a producción — Chasqui

> **2026-08-14 — Este documento queda como registro histórico de las Fases 1-4.**
> La hoja de ruta vigente es la del roadmap de inteligencia empresarial, que
> reordena todo lo que sigue contra una sola pregunta: *¿esta pieza hace que
> Chasqui entienda mejor el negocio, recomiende algo mejor o permita ejecutar
> una decisión?* Cambios respecto de lo escrito abajo:
>
> - **Congelados**: cotizador, cobro automático, facturación electrónica,
>   PDF/Gotenberg, bot público (Fase 4), pgvector, Supabase, RLS, Directus, y
>   los Niveles 2 y 3 del comparativo externo (§3.5) hasta que exista el
>   cerebro propio contra el cual comparar.
> - **Cartera** (Fase 2) solo sigue viva si alimenta `recomendaciones_negocio`
>   como señal de liquidez; como pantalla informativa, congelada.
> - **Fases nuevas**: integridad de datos (historia completa, inventario
>   declarado, impacto tipado), cerebro acumulativo (snapshot + recomendaciones
>   persistentes + comparativas), preguntar a los números, ejecutar y medir,
>   proactividad.
> - **Cuatro restricciones globales**: Postgres calcula y el LLM redacta; el
>   plan limita lectura y nunca almacenamiento; una recomendación persiste y se
>   evalúa después; cada pieza nueva aumenta conocimiento, mejora una
>   recomendación o permite ejecutar/medir una decisión.
>
> **Aplicado hasta ahora**: migración `053` (historia completa) — el plan
> gratuito dejó de descartar filas; el filtro pasó de escritura a lectura vía
> la vista `mov_visibles`.

Estado: Fase 1 empezada. Fecha: 2026-07-25.

Implementado: migraciones `029` (funcion_hallazgos + identidades + conocimiento),
`030` (servicio `consulta`, `/saber`, texto libre en el router), `031` (la
estructura del informe seco sale de Postgres, no de un nodo), `032` (la
plantilla de entrega la elige el servicio), `033` (PostgREST, magic link
`/portal`, RPC del portal) y `034` (ninguna función es pública por defecto).
Al compose entraron `postgrest` y `proxy` (Caddy), y cloudflared pasó a apuntar
al proxy: el editor de n8n dejó de estar expuesto en internet.

Falta de la Fase 1: solo Directus, que se pospuso a propósito —es back-office
nuestro, no del cliente, y no destraba nada del portal—.

Premisa: Chasqui sigue siendo la ventana de entrada por mensajería con servicios
chicos (el análisis que ya existe, cartera). Todo lo que necesite más pantalla o
más criterio se resuelve en un portal web que **extiende** el bot, no lo
reemplaza. La filosofía no cambia: el comportamiento vive en filas de Postgres y
n8n sigue siendo runtime fijo.

---

## 1. Decisiones tomadas (y lo que se descarta del plan original)

| Pieza | Decisión | Por qué |
|---|---|---|
| Supabase | **No migrar** | Mover la base + reconectar n8n + retrofit de RLS. RLS no protege de nada mientras el único escritor sea n8n (backend confiable). Hoy el aislamiento es `negocio_id` dentro de funciones y funciona. |
| Auth (Clerk/WorkOS/Supabase Auth) | **No comprar** | Telegram ya es la identidad. `/portal` → el bot manda enlace con token firmado de un uso → sesión web. Cero vendor, cero recuperación de contraseña, cero invitaciones. |
| API propia (Node/Python) | **No escribir** | **PostgREST** contra el Postgres actual expone las funciones como HTTP con claims en el JWT. Un contenedor más, cero código de backend. Escribir una API sacaría lógica de Postgres — justo lo que el diseño evita. |
| Refine / React Admin | **No** | Panel genérico = lo contrario del "modo tendero". Para 5 pantallas, HTML plano es más rápido. |
| Directus | **Sí, pero interno** | Back-office de operación (nuestro), no del cliente. |
| ERPNext / Odoo (Ruta A) | **Descartado** | Obliga a pelear contra el framework para simplificar la UI; el fork se rompe en cada actualización. |
| Facturación electrónica | **Fuera de alcance** | Solo si un cliente la pide y paga por ella. Entonces: Alegra / Factus / Siigo API. |
| WhatsApp | **Fase 3** | Arrancar la verificación de Meta ya: es tiempo de calendario, no de trabajo. |
| Cobros | **Enlace de Wompi manual** | No construir suscripciones hasta tener a quién cobrarle. |

---

## 2. La decisión que hace rápido todo lo demás

**El chat no crece.** Todo lo que necesite más de un turno o más de un campo
vive en el portal; en chat es un enlace.

- **Chat:** subir archivo → informe. Una pregunta → una respuesta. Botón → enlace.
- **Portal:** lista de precios, base de conocimiento, cotizador, perfil, historial.

Razón técnica: `router_procesar_mensaje` (`db/migraciones/024_router_botones.sql:42`)
es una máquina de estados en plpgsql con pasos cableados, y `servicios.pasos`
modela guion de intake de archivos, no formularios. Convertirlo en intérprete de
formularios es el trabajo más grande y frágil de todo el plan, y es innecesario
si el portal existe.

---

## 3. La pieza clave: `servicios.funcion_hallazgos`

Hoy `ejecucion_preparar` llama `hallazgos_generar(v_negocio_id)` cableado
(`db/migraciones/008_ejecucion_operacion.sql:45`), sin pasar `servicio_codigo`.
Es el bloqueador #1: cualquier servicio nuevo con otros números recibiría los
hallazgos de ventas-compras.

Una columna nueva en `servicios` con el nombre de la función a invocar convierte
en **filas** todo lo que sigue:

| Servicio | `funcion_hallazgos` | Workflows nuevos |
|---|---|---|
| ventas_compras (existe) | `hallazgos_generar` | 0 |
| cartera | `hallazgos_cartera` | 0 |
| consulta (preguntar a tu propio negocio) | `conocimiento_recuperar` | 0 |
| cotizador | `cotizacion_armar` | 0 |

wf_ejecutar ya hace preparar → LLM → render → validar → cerrar, y es genérico.
**Esta migración va primera**; sin ella, cada servicio nuevo toca n8n.

---

## 4. Base de conocimiento

```sql
CREATE TABLE conocimiento (
    id, negocio_id, tipo,          -- precio | politica | horario | faq | condicion
    clave, titulo, contenido text,
    datos jsonb,                   -- {valor, unidad, ...} para lo que es cifra
    origen text,                   -- chat | portal | archivo
    vigente_desde date, vigente_hasta date,
    actualizado_en, actualizado_por
);

CREATE TABLE conocimiento_pendiente (   -- el motor del producto
    negocio_id, pregunta text, veces int, resuelto_por bigint
);
```

**Recuperación v1: sin pgvector.** `pg_trgm` + `unaccent` ya están instalados;
para una pyme con <300 filas, buscar y meter el top-N en el prompt es más barato
y más depurable que embeddings. pgvector cuando un tenant pase ese umbral, y el
embedding lo pide n8n por HTTP igual que hoy pide el LLM.

### Tres vías de alimentación

1. **Portal** — formularios. Aquí se construye y mantiene la lista maestra de precios.
2. **Chat** — `/saber <texto>`, y sobre todo: **cada pregunta que el bot no sabe
   responder se inserta en `conocimiento_pendiente`**. No se le pide al dueño que
   documente su negocio de entrada; se le cosecha el conocimiento de preguntas
   reales, ordenado por frecuencia. Ataca de frente el "no hay nada que el bot
   pueda responder".
3. **Archivo** — casi gratis: `formatos_documento.funcion_parseo` ya es una
   columna, y la ingesta tabular ya aprende layouts desconocidos con el LLM y los
   persiste (`db/migraciones/017_ingesta_tabular.sql`). Una lista de precios en
   Excel es un INSERT en `formatos_documento` + una función que escriba en
   `conocimiento` en vez de `movimientos`.

---

## 5. Cambios necesarios en el código existente

| # | Cambio | Dónde |
|---|---|---|
| 1 | `servicios.funcion_hallazgos` + despacho | `db/migraciones/008_ejecucion_operacion.sql:45` |
| 2 | Tabla `identidades (canal, id_externo, usuario_id)`; `usuario_de_telegram` → `usuario_de_canal`. Habilita WhatsApp y la sesión del portal | `db/migraciones/012_router.sql:31`, `usuarios.telegram_user_id UNIQUE` en `db/migraciones/001_nucleo.sql:24` |
| 3 | `validar_cifras(texto, fuentes jsonb)` — hoy solo valida contra `hallazgos`; las cifras del cotizador vienen de `conocimiento` y las rechazaría como inventadas | `db/migraciones/026_fix_cifras_miles.sql:65` |
| 4 | Router: solo dos comandos nuevos (`/portal`, y texto libre → servicio `consulta`). Nada de formularios | `db/migraciones/024_router_botones.sql:42` |
| 5 | Tope de teclado: con 4 servicios + Cancelar se llega al límite de 6 filas | `bin/gen_wf_enviar.py` (`MAX_FILAS`) + `parametros.teclado_max_filas` |
| 6 | Gotenberg vuelve a tener uso: la cotización en PDF | ya está en `docker-compose.yml:80` |

---

## 6. Secuencia

### Fase 1 — habilitar (lo más corto que produce algo vendible)
- ✅ Migración `029`: `funcion_hallazgos` + `identidades` + `conocimiento` + `conocimiento_pendiente`.
- ✅ Servicio `consulta` (texto libre sobre la KB) como fila, migración `030`.
  Cero workflows nuevos; `servicios.entrada` distingue los que piden archivos de
  los que se disparan escribiendo. `/saber` alimenta la KB desde el chat y una
  pregunta sin respuesta se anota sin gastar tokens.
- ✅ PostgREST al compose, detrás de Caddy. Migraciones `033` y `034`: el rol web
  no puede leer ninguna tabla ni ejecutar ninguna función que no sea `portal_*`.
- ✅ Magic link `/portal`: token de un uso → JWT firmado en SQL.
- ✅ Portal mínimo, 4 pantallas: `portal/publico/index.html`, HTML plano.
- ✅ Menú de dos niveles, migraciones `045`-`046`: la bienvenida presenta a
  Chasqui sin pedir ninguna decisión ni nombrar servicios, e invita a escribir;
  los análisis cuelgan de un **módulo** (tabla `modulos`) detrás del botón "¿Qué
  puedo hacer?". Antes del primer análisis se pregunta la naturaleza del negocio
  (`tipos_negocio` → `negocios.tipo`). El teclado fijo se probó y se descartó por
  saturar la vista. Perfil del bot, comandos por ámbito y botón de menú los pone
  `bin/configurar-bot.sh`. El inventario completo de la Bot API está en
  `docs/TELEGRAM_UX.md`.
- ✅ **Informe prescriptivo**, migración `047`: el informe dejó de describir y
  pasó a recetar. `recomendaciones_negocio` calcula en SQL, por regla, el impacto
  en pesos de cada problema, las opciones y la prioridad; `salud_negocio` da
  cinco notas de 0 a 100 y un índice. El modelo solo redacta —el detalle y el
  porqué están en `docs/GUIA_TECNICA.md` §4.6—.
- Directus: pospuesto. Es back-office nuestro y no lo necesita ningún servicio.

### Fase 2 — el primer servicio que se cobra
- **Cotizador** en portal: selecciona productos de `conocimiento` tipo precio → PDF por Gotenberg. En chat solo el enlace.
- **Cartera**: `terceros` + `facturas` (número, emisión, vencimiento, total, saldo) + `pagos`; `movimientos.tercero_id`; parser DIAN que lea `cbc:DueDate`/`cac:PaymentMeans` y decida venta vs compra comparando `negocios.nit` contra `AccountingSupplierParty` (hoy fuerza `tipo='compra'`, `db/migraciones/004_ingesta.sql:110`). Vistas `v_cartera_edades`, `v_cartera_tercero`. **Reporta al dueño; no persigue deudores** (eso exigiría canal saliente a terceros).

### Fase 3 — canal y cobro
- WhatsApp: `wf_whatsapp` es un webhook que llama al mismo `router_procesar_mensaje`; lo habilita el cambio #2.
- Cobro: enlace de Wompi manual / comando `/plan`.
- **Mini App**: el portal deja de abrirse por magic link y pasa a abrirse dentro
  de Telegram con un botón `web_app`; la sesión se valida por HMAC del
  `initData` en una variante de `portal_sesion_abrir`, sin token de 15 minutos.
  El magic link queda de respaldo para escritorio.
- **Edición de mensajes** (`editMessageText`): el wizard deja de apilar mensajes
  —entrar a un módulo edita el que ya está— y el informe se pagina con `◀️ ▶️`.
  Diseño de las dos en `docs/TELEGRAM_UX.md`.

### Fase 3.5 — el motor de recomendaciones, niveles 2 y 3

El motor de la migración `047` es **Nivel 1**: compara al negocio contra su
propio historial. Eso ya responde "hace tres meses lo comprabas 12% más barato" y
"este proveedor te subió tres veces este año". Los dos niveles que siguen no
cambian el contrato de `recomendaciones_negocio` —siguen siendo filas con
impacto, opciones y prioridad—: cambia de dónde sale el comparativo.

- **Nivel 2 — precios oficiales.** Ingesta periódica de SIPSA (DANE) a una tabla
  `precios_referencia(producto, mercado, fecha, precio)`. Habilita la regla que
  hoy no se puede escribir: *"el arroz subió 4% en el mercado y vos pagaste 11%:
  estás pagando por encima"*. Necesita mapear productos del negocio a la
  nomenclatura del DANE — el mismo problema de matching que ya resuelve `alias`,
  contra otro catálogo.
- **Nivel 3 — benchmark entre negocios.** Con cientos de negocios cargando
  compras, `precio_mercado_producto` (anonimizada, por tipo de negocio y ciudad)
  responde *"el 73% de negocios como el tuyo paga este producto entre $6.900 y
  $7.100"*. **Requiere consentimiento explícito y agregación con mínimo de N**
  para que un precio no sea trazable a un negocio; sin eso no se activa.
- **Catálogo de equivalencias.** `producto_categoria` + marcas sustitutas
  ("aceite vegetal 1 L": Premier, Gourmet, Rica Palma…). Es lo que convierte
  *"buscá otra marca"* en *"pasate a Gourmet, que mantiene tu margen y está 8%
  más barato"*. Se construye de a poco, y las primeras filas salen de lo que ya
  compran los propios negocios.

Orden recomendado: catálogo de equivalencias → Nivel 2 → Nivel 3. El primero
mejora recomendaciones que ya existen; el tercero no sirve hasta tener volumen.

### Fase 4 — empleado personal (bot público)
- Segundo webhook + `router_responder_publico`, que **solo** lee `conocimiento`, nunca sesiones ni movimientos, con fallback duro a "no sé, te contacto".
- **No activarlo hasta que el tenant tenga la KB poblada**, o falla exactamente como predice el análisis de mercado.

---

## 7. Lo que no se toca antes del primer cliente que paga

Facturación electrónica, RLS, suscripciones, pgvector, migración a Supabase,
multi-canal simultáneo.

---

## 8. Los 4 casos que obligan a abrir n8n

1. Más de 5 servicios activos (tope de teclado).
2. Canal nuevo o segundo bot → webhook nuevo → workflow nuevo.
3. Salida a destinatarios que no son usuarios registrados (recordatorio al deudor):
   `wf_enviar` resuelve `chat_id` desde `usuarios`.
4. Fuente que no sea archivo subido (API de banco, ERP) → nodo HTTP nuevo.

Fuera de esos cuatro, un servicio nuevo es un INSERT.

---

## 9. Riesgo principal

No es técnico: es que el portal se convierta en un ERP. La regla que lo contiene:
**una pantalla nueva solo si un servicio existente la necesita para funcionar.**
`conocimiento_pendiente` decide qué construir después, no la intuición.
