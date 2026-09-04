# Chasqui — inteligencia empresarial por Telegram para pymes


** Chasqui nace con la idea de facilitar al maximo el acceso a servicios - que genheralmente no puden acceder por costos o por desconocimiento de la existencia del servicio- generalmente incluidos en soluciones para grandes compañias o de facilidades para sus negocios a dueños de pymes por medio de aplicaciones de mesnajeria.

n8n como runtime fijo; **todo el comportamiento vive en filas de Postgres**.
Agregar un servicio es SQL (INSERT), no abrir el editor de n8n.

## Estado — Chasqui v0, base limpia

**Esto es v0 y la instalación de esta máquina ya está en v0.** No hay que
"pasarse" a nada, no hay que aplicar las 73 migraciones viejas y no hay una base
alterna: la base `chasqui` se instaló desde `db/base/` el 2026-08-19, tiene las
73 selladas más la `074`, la `075` y la `076`, el producto completo (82
plantillas, 3 servicios, 35
parámetros) y **cero datos de negocio**.

Está así a propósito, para hacer pruebas de usuario sobre una instalación
idéntica a la que recibiría un cliente nuevo. Lo que sigue no se decide otra vez:

| | |
|---|---|
| instalar desde cero | `bash bin/migrar.sh` sobre base vacía: aplica `db/base/` y sigue en la `074` |
| el próximo cambio de SQL | migración `077` en `db/migraciones/`, y empieza por un pedido |
| las 73 viejas | `agent-context/history/migraciones/`. **No se aplican ni se consultan para saber cómo funciona algo** |
| cómo funciona algo hoy | `db/actual/` |
| qué gobierna | `decisiones/` — 21 decisiones vigentes |
| volver a dejar la base limpia | `bash bin/limpiar_negocio.sh` y nada más |

### Arrancar una prueba de usuario

```bash
docker compose --profile local up -d      # incluye cloudflared + registrador
docker compose logs registrador --tail 5  # tiene que decir: ok · portal_url_base = https://…
```

El registrador descubre el túnel, registra el webhook de Telegram y escribe
`portal_url_base`. Si dice `ERROR: fallo de red` es que el hostname del quick
tunnel todavía no propagó en el DNS que usa Telegram: `docker compose restart
cloudflared` toma otro y en un minuto queda. Después, `/start` en el bot crea
negocio y usuario solos — no hay que sembrar nada a mano.

## Por dónde empezar

| Quieres… | Abre |
|---|---|
| pedir un cambio | la skill `/pedido` — el humano no edita el repo a mano (`PROCESO-001`) |
| ver qué cambios están en curso | `bash bin/pedidos.sh` · `pedidos/README.md` |
| ver qué se construyó y con qué prueba | Quipu, `localhost:8001` (`PROCESO-002`) |
| trabajar en el proyecto (humano) | `GUIA_TRABAJO.md` |
| trabajar en el proyecto (agente de código) | `AGENTS.md` |
| la documentación del sistema | `agent-context/README.md` |
| saber qué existe hoy: funciones, vistas, tablas | `db/actual/INDICE.md` |
| qué gobierna y qué se descartó | `decisiones/INDICE.md` |
| qué ve el usuario final | `agent-context/product/guia-funcional.md` |
| cómo está construido y por qué | `agent-context/operations/guia-tecnica.md` |
| qué falta | `ROADMAP.md` |

Cuatro registros y no se mezclan (`DOCS-001`):

| Pregunta | Responde |
|---|---|
| ¿qué debe ser? | `decisiones/` — normativo |
| ¿cómo está hoy? | `db/actual/` — generado del catálogo vivo |
| ¿cómo funciona, en prosa? | `agent-context/` — describe, no gobierna |
| ¿qué se está cambiando? | `pedidos/` — el expediente: qué, por qué, quién autorizó |
| ¿qué se construyó y con qué prueba? | Quipu — la evidencia, no la norma |

La última pregunta —*¿por qué llegó a ser así?*— la responde
`agent-context/history/`: las 73 migraciones selladas, las auditorías y los
planes ya ejecutados. Es parte de la documentación y no gobierna nada.
`ejemplos/` son fixtures de prueba.

## Arquitectura

- **Postgres** (base `chasqui`) es el sistema completo: esquema, funciones, vistas,
  textos, **botones**, prompts, layout del informe, umbrales y los archivos
  originales (bytea).
- **n8n** (base `n8n`, separada) orquesta lo que Postgres no puede: HTTP al LLM,
  descarga de archivos, envío por Telegram.
- **PostgREST** publica la base como HTTP para el portal, sin una línea de
  backend. Su rol no tiene permiso sobre ninguna tabla: lo único ejecutable son
  las funciones `portal_*`, y cada una saca el `negocio_id` del JWT, nunca de un
  parámetro.
- **Caddy** (`proxy`) es el único puerto público: `/webhook` va a n8n, `/api` a
  PostgREST y `/portal` al HTML plano de `portal/publico/`. El editor de n8n
  dejó de estar en internet; queda solo en `127.0.0.1:5678`.
- **cloudflared + registrador** exponen el proxy en local, mantienen el menú de
  comandos del bot y le escriben a la base la URL pública del momento (la usa el
  enlace de `/portal`). **Gotenberg ya no está en el compose**: el informe se
  entrega como texto en el chat y lo que no cabe va al portal (`PRODUCTO-002`).

## El portal

Sin contraseñas: la identidad es Telegram. `/portal` en el bot manda un enlace
con un token de un solo uso y 15 minutos de vida; el navegador lo cambia por un
JWT de 12 horas (`portal_sesion_abrir`, que firma en SQL con el secreto que
PostgREST inyecta como GUC). Cuatro pantallas: mi negocio, precios,
conocimiento —incluidas las preguntas que el bot no supo responder— e informes.

## Los 7 workflows

| Workflow | Dispara | Hace |
|---|---|---|
| wf_router | Webhook `/telegram` | Normaliza el update (un toque de botón entra por el mismo camino que un mensaje) → `router_procesar_mensaje` → despacha respuestas[] y acciones[] |
| wf_ingesta | Sub-workflow | Descarga archivo → bytea → parseo (DIAN XML, o tabla csv/xls/xlsx/ods identificada por huella de cabeceras) → matching |
| wf_ejecutar | Sub-workflow | `ejecucion_preparar` → el LLM (devuelve JSON con la estructura) → `informe_render` → `validar_cifras` → `ejecucion_cerrar` |
| wf_enviar | Sub-workflow | Único punto de salida: resuelve plantillas **con sus botones** y manda texto/documento por Telegram |
| wf_cron | Schedule 5 min | `mantenimiento_ciclo`: reaper de colgadas + expiración de sesiones |
| wf_error | Error Trigger | Registra en `fallas`, clasifica transitoria, avisa a admins |

> El 7º workflow del plan (wf_admin) NO existe como workflow: con un solo bot hay un
> solo webhook. Los comandos de admin (`/salud /embudo /fallas /consumo /matching`)
> viven dentro de `router_procesar_mensaje`, restringidos por `usuarios.rol`. Es
> exactamente el "cero código nuevo" que pide el plan.

## Puesta en marcha (local)

```bash
cp .env.example .env         # ya viene con secretos generados y tokens del prototipo
docker compose --profile local up -d   # incluye cloudflared + registrador
bash bin/preparar-portal.sh  # roles de PostgREST (superusuario; una sola vez)
bash bin/migrar.sh           # aplica db/migraciones/*.sql
```

El orden importa: `preparar-portal.sh` crea los roles `authenticator`,
`portal_anon` y `portal_usuario`, y la migración `033` les da permisos. `CREATE
ROLE` no está al alcance del dueño de la base, por eso no es una migración.

Luego, en la GUI (http://localhost:5678):
1. Crea la cuenta de propietario (primer arranque).
2. Las 3 credenciales ya están importadas (Chasqui Postgres, Chasqui Telegram, DeepSeek Header).
3. **Activa los 7 workflows.**
4. En *Settings → Error Workflow* de cada uno, selecciona **wf_error**.
5. El servicio `registrador` ya apuntó el webhook de Telegram al túnel actual.

### Tu usuario

No se siembra nada: `/start` crea usuario y negocio por la ruta real
(`PLANES-001`). Lo único que se hace a mano es subirte a admin, y sólo si querés
los comandos de admin:

```sql
UPDATE usuarios SET rol = 'admin' WHERE telegram_chat_id = <TU_CHAT_ID>;
```

## Probar sin Telegram

```bash
# motor completo (genera el informe y lo deja en ejecuciones.texto):
docker compose exec postgres psql -U chasqui -d chasqui -c \
  "INSERT INTO ejecuciones (negocio_id, servicio_codigo, estado) VALUES (1,'ventas_compras','preparando');"
docker compose exec -e N8N_RUNNERS_BROKER_PORT=5699 n8n n8n execute --id wfEjecutar000000001
```

## Archivos de ejemplo

`ejemplos/` tiene los archivos numerados en el orden en que se le mandan al bot:

| Archivo | Qué prueba |
|---|---|
| `01_compra_factura_simple.xml` | Factura DIAN UBL 2.1 mínima (Invoice, 2 líneas). Crea los primeros productos y costos. |
| `02_compra_factura_adjunta.xml` | AttachedDocument con el Invoice real envuelto en CDATA, como llegan del proveedor tecnológico. |
| `03_compra_proveedor_4productos.xml` | Factura DIAN, 4 líneas con código de barras (matching exacto). Fija los costos. |
| `04_ventas_formato_conocido.csv` | Formato conocido: se identifica por huella, sin gastar tokens. |
| `05_ventas_otro_pos_para_aprender.xlsx` | **Formato desconocido**: cabeceras ajenas, fecha `dd/mm/yyyy`, decimal coma. El LLM infiere el mapeo, se persiste, y el siguiente archivo igual ya no llama al LLM. |

Después de cargar las compras, `python3 bin/gen_ventas_demo.py` genera un
`ventas_demo_*.csv` con reventas derivadas de esas compras (`--cargar` lo mete
directo a la base por el mismo camino que la ingesta).

## La ingesta no exige un esquema

Un `.xlsx` o un CSV de cualquier POS entra igual. El formato se identifica por la
**huella de sus cabeceras**; si es nueva, el LLM ve solo los nombres de columna y
5 filas de muestra y devuelve un `mapeo`, que se valida y se guarda como fila de
`formatos_documento`. **Las cifras nunca pasan por el modelo**: las carga
Postgres con ese mapeo. El segundo archivo del mismo POS no gasta un token.

Si el mapeo no aplica (más del 20% de filas sin fecha o sin valor), el documento
va a `error` con un motivo que nombra la columna, y **no se inserta ni una fila**.
Antes se cargaba todo en NULL y se reportaba éxito.

## Agregar un servicio nuevo (la prueba que importa)

Sin tocar n8n:
```sql
INSERT INTO servicios (codigo, nombre, ...) VALUES ('nuevo', ...);
INSERT INTO servicios_entradas (...) VALUES (...);
INSERT INTO formatos_documento (...) VALUES (...);   -- solo si querés fijar el mapeo a mano
INSERT INTO prompts (servicio_codigo, sistema, usuario, ...) VALUES ('nuevo', ...);
```

El botón del servicio aparece solo: el menú se arma con `teclado_intake()`
leyendo los servicios activos del módulo. El prompt sí tiene un contrato que respetar —debe
devolver el JSON que espera `informe_render`— y el teclado tope 6 botones; el
detalle está en `agent-context/operations/guia-tecnica.md` §6.4 y §11.

## Respaldo

`bash bin/respaldo.sh` — pg_dump de ambas bases. La base ES la herramienta entera.

## Riesgo abierto

Los fixtures DIAN (`ejemplos/`) son sintéticos (anexo técnico 1.9). Los totales
cuadran contra los propios fixtures, **no contra XML real de cliente**. Re-verificar
en cuanto haya facturas reales antes de dar la ingesta por confiable.
