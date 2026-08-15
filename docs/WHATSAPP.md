# WhatsApp como segundo canal

WhatsApp entra por la Cloud API de Meta y usa el **mismo cerebro** que Telegram:
`wf_wa_router` normaliza el webhook al mismo evento (`canal: 'whatsapp'`) y llama
a `router_procesar_mensaje`. La identidad se cuelga en `identidades`
(canal + wa_id), el `chat_id` que viaja por los sobres es el teléfono en dígitos,
y `wf_enviar` decide al final por qué canal contestar (`canal_de_chat`, migración
044). No hay una segunda máquina de estados.

## Qué hay que conseguir en Meta (checklist)

Todo en <https://developers.facebook.com> con una cuenta de Facebook:

1. **App de Meta** de tipo *Business* con el producto **WhatsApp** agregado.
   - `WA_APP_ID` y `WA_APP_SECRET`: App > Configuración básica.
2. **Cuenta de WhatsApp Business (WABA)**: se crea sola al agregar el producto.
   - `WA_WABA_ID`: WhatsApp > Configuración de la API.
3. **Número de teléfono**:
   - Para probar: Meta regala un número de prueba (permite hasta 5 destinatarios
     que hay que registrar a mano en la misma pantalla).
   - Para producción: un número real **que no esté registrado en la app normal
     de WhatsApp** (o hay que darlo de baja primero), verificable por SMS/llamada.
   - `WA_PHONE_NUMBER_ID`: WhatsApp > Configuración de la API ("ID del número
     de teléfono" — es un id de Meta, no el teléfono).
4. **Token permanente**: Business Manager (business.facebook.com) >
   Configuración del negocio > Usuarios > Usuarios de sistema: crear un usuario
   de sistema, asignarle la app y generar un token con permisos
   `whatsapp_business_messaging` y `whatsapp_business_management`.
   - `WA_ACCESS_TOKEN` en `.env` **y** el mismo token en la credencial de n8n
     (ver abajo). El token temporal de la consola dura 24 h: sirve para la
     primera prueba, no más.
5. **Para salir de sandbox** (mensajes a cualquier número): verificación del
   negocio en Business Manager (documentos de la empresa) y nombre para mostrar
   aprobado. Sin eso, el número de prueba y sus 5 destinatarios alcanzan para
   todo el desarrollo.

Lo que se inventa acá (no viene de Meta): `WA_VERIFY_TOKEN`
(`openssl rand -hex 24`) y `WA_WEBHOOK_PATH` (con sufijo aleatorio: hace de
secreto de la ruta, porque Meta no manda cabecera secreta como Telegram).

## Activación (cuando estén las credenciales)

1. Rellenar el bloque WhatsApp de `.env`.
2. Crear en n8n la credencial **Header Auth** llamada `Chasqui WhatsApp`:
   Name `Authorization`, Value `Bearer <WA_ACCESS_TOKEN>`.
3. `bash bin/migrar.sh` (aplica 044 si no está).
4. Regenerar e importar con el `.env` cargado:
   `set -a; . ./.env; set +a` y luego `python3 bin/gen_wf_wa_router.py`,
   `gen_wf_enviar.py`, `gen_wf_ingesta.py`, `gen_wf_router.py`;
   `bash bin/importar-workflows.sh`.
5. Aplicar los cambios del compose al servicio `registrador` (nuevas variables
   WA_*): se recrea solo ese contenedor al siguiente `docker compose up -d`.
   El registrador re-apunta la suscripción de Meta cada vez que cambia la URL
   del túnel, igual que hace con Telegram.
6. Probar: escribir al número desde WhatsApp → debe llegar la bienvenida con
   botones nativos.

## Diferencias de la interfaz respecto a Telegram

| | Telegram | WhatsApp |
|---|---|---|
| Botones bajo el mensaje | hasta 6 filas | máx **3** botones (reply buttons) |
| Más de 3 opciones | más filas | **lista** desplegable (máx 10 filas, botón "Ver opciones") |
| Texto | HTML | `*negrita*` `_cursiva_` (conversión `wa_texto`, 044) |
| Cuerpo con botones | 4096 chars | máx **1024**: un texto largo con botones sale como texto + interactivo corto (`wa_payload`) |
| Botones URL | inline | no existen en button/list: la URL va como línea al final del cuerpo |
| Iniciar conversación | siempre | solo dentro de las **24 h** desde el último mensaje del usuario; fuera de eso exige *message templates* aprobadas |

La ventana de 24 h no afecta el flujo normal (el bot siempre responde a algo que
el usuario acaba de mandar), pero **los recordatorios del cron y los avisos de
mantenimiento no salen por WhatsApp** hasta que haya plantillas aprobadas; esos
usuarios simplemente no los reciben si su única identidad es WhatsApp.

## Pendientes conocidos

- Verificar la firma `X-Hub-Signature-256` del webhook (hoy la defensa es la
  ruta secreta + el filtro por `phone_number_id`).
- *Message templates* para notificaciones proactivas (recordatorio de sesión,
  avisos del cron).
- Cobro por conversación de Meta: la conversación de servicio (iniciada por el
  usuario) es la barata; vigilar consumo cuando haya volumen.
