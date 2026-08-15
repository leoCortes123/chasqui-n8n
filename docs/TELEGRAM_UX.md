# Telegram como interfaz: herramientas evaluadas y plan

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

## Fase siguiente

5. **Mini App para el portal** (decisión tomada: vía principal). Botón `web_app`
   en el menú y en los teclados, que abre el portal DENTRO de Telegram;
   autenticación validando `initData` (HMAC con el token del bot) en una
   variante de `portal_sesion_abrir` — sin magic link de 15 minutos, sin
   navegador. El magic link queda de respaldo para escritorio. El nodo de
   Telegram de n8n sí declara `web_app.url` en los botones, así que el envío no
   es el problema; lo es la validación de `initData`, que necesita el token del
   bot dentro de Postgres o de n8n. `setChatMenuButton` pasa de `commands` a
   `web_app` en `bin/configurar-bot.sh`.
6. **Edición de mensajes** (`editMessageText` / `editMessageReplyMarkup`):
   wizard en un solo mensaje (entrar a un módulo edita el mensaje en vez de
   apilar otro), retirar los teclados ya usados, e **informe paginado** con
   `◀️ ▶️` en lugar de tres mensajes seguidos.
7. **Botones con color y emoji custom** (Bot API 9.4: `style`,
   `icon_custom_emoji_id`): `Analizar` primario, `Cancelar` destructivo. Son
   campos extra en el JSONB de `plantillas.teclado`; el nodo de n8n no los
   declara, así que llegan junto con el punto 8.
8. **Rich Messages** (Bot API 10.1: tablas, encabezados, galerías): candidato
   para el informe; requiere HTTP Request contra `api.telegram.org` (el nodo
   Telegram no lo soporta), y eso significa meter `TELEGRAM_BOT_TOKEN` en el
   contenedor de n8n. Evaluar al rediseñar el informe.

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
