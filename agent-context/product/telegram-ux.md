# Telegram como interfaz: herramientas evaluadas y plan

> **Vigencia.** Documento descriptivo: registra qué ofrece la Bot API y qué se
> decidió con cada cosa. No gobierna —eso es `decisiones/`— y si contradice a
> `db/actual/`, manda `db/actual/`. Revisado el 2026-08-22.

Filosofía: Telegram (y ahora WhatsApp, ver `WHATSAPP.md`) es la interfaz de
usuario. Prioridad: **máxima accesibilidad** — el usuario no escribe comandos,
todo se toca. Los teclados inline se definen en `plantillas.teclado`
(migración 023) y el router trata igual un botón que un texto escrito. Este
documento registra qué más ofrece la Bot API (a julio 2026), qué se decidió con
cada cosa, y cómo quedó la conversación después de las migraciones 045 y 046.

## La conversación desde /start

```
sistema.bienvenida     "Soy Chasqui, un asistente para tu negocio. Contame qué
                        tenés en mente…". No nombra ningún servicio.
  🔎 ¿Qué puedo hacer?             -> mod:negocio

sistema.modulo         el titular del módulo + sus servicios
  Análisis de ventas y compras      -> svc:ventas_compras
  Mercado de compras                -> svc:mercado_compras
  ❓ Cómo funciona                  -> modayuda:negocio
  ⬅️ Volver                        -> /ayuda

sistema.pedir_tipo     ¿minimercado, almacén, distribuidora…?  -> tipo:<codigo>
sistema.pedir_archivos
```

Tres decisiones detrás de esa forma:

1. **El primer mensaje no pide nada y no vende nada.** Es la única oportunidad
   de que alguien entienda qué es esto; abrir con "¿qué análisis necesitás?" es
   pedir una decisión antes de haber explicado nada. Y como la puerta principal
   es escribir libremente (el servicio `consulta`), la bienvenida invita a eso
   antes que a un menú.
2. **Los servicios cuelgan de un módulo** (tabla `modulos`, migración 045). Un
   módulo es un botón en la bienvenida y sus servicios activos son el segundo
   nivel. Agregar un módulo es un INSERT; mover un servicio, un UPDATE. Y cada
   nivel gasta pocos de los 6 botones del tope (migración 027).
3. **La naturaleza del negocio se pregunta una vez** antes del primer análisis
   (migración 046) y queda en `negocios.tipo`: los mismos números se leen
   distinto en un minimercado y en una distribuidora.

## Adoptado (migraciones 045-046 + `bin/configurar-bot.sh`)

1. **Perfil del bot** (`setMyDescription`, `setMyShortDescription`): la pantalla
   "¿Qué puede hacer este bot?" con botón *Iniciar*. El primer contacto ya es
   sin escribir. Lo pone `bin/configurar-bot.sh`.
2. **Menú de comandos con ámbitos** (`setMyCommands` + `setChatMenuButton`):
   el ámbito de defecto solo tiene comandos de usuario; `/salud`, `/embudo`,
   `/fallas`, `/consumo`, `/matching`, `/pendientes` y `/admin` se registran en el ámbito de
   cada chat de admin, que sale de `usuarios.rol` — no de una variable de
   entorno. Para el resto de la gente esos comandos no existen.
   El registrador ya no toca el menú (pisaba la separación en cada reconexión
   del túnel): eso ahora es responsabilidad de `bin/configurar-bot.sh`.
3. **`sendChatAction`** ("escribiendo…") al arrancar el análisis, en
   `wf_ejecutar`. Va en la cadena y no como rama suelta: el sub-workflow le
   devuelve al padre la salida del último nodo ejecutado, y una rama paralela
   puede quedarse con ese lugar y dejar a `wf_enviar` sin informe.
4. **Deep links** (`t.me/<bot>?start=...`): base para el QR impreso de
   onboarding. Ya funciona porque `/start` es un comando más.

## Ideas sin decisión escrita

Lo que estaba acá como «fase siguiente» se limpió el 2026-08-22: el punto 6
(edición de mensajes) **ya está implementado** desde la `070` —el panel de carga
se edita en su lugar (`INGESTA-002`)—, y lo que seguía pendiente pasó a
`ROADMAP.md`, que es el único registro de lo abierto.

Nada de lo que quede escrito acá gobierna: una idea entra al sistema por una
decisión en `decisiones/` y un pedido en `pedidos/`, nunca por un párrafo de este
archivo (`PROCESO-001`).

## Descartadas

- **Teclado fijo** (reply keyboard). Se implementó en la 045 y se quitó en la
  046: satura la vista, y en el plan gratuito la interacción es solo por chat
  —el portal es para después—. Se borró la maquinaria entera (tabla
  `atajos_teclado`, `plantillas.teclado_fijo`, el nodo de envío): dejarla
  apagada era peor que no tenerla. Si algún día vuelve, el límite ya conocido es
  que `is_persistent` e `input_field_placeholder` no se pueden poner —el nodo de
  n8n solo declara `resize_keyboard`, `one_time_keyboard` y `selective`—.
- **Inline mode** y **attachment menu**: no aplican al caso de uso.
- **Checklists** (10.2): sin caso claro.
- **`request_contact`**: la identidad ya es el chat.

## Dónde vive cada cosa

| Qué | Dónde |
| --- | --- |
| Módulos, su titular y su ayuda | tabla `modulos` |
| A qué módulo pertenece un servicio | `servicios.modulo_codigo` |
| Naturaleza del negocio (los botones) | tabla `tipos_negocio` |
| Perfil, comandos y botón de menú | `bin/configurar-bot.sh` |
