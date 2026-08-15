# Guía funcional — Chasqui

Para entender **qué hace** Chasqui, **para quién** y **cómo se usa**, sin entrar
en la técnica. Pensada para producto, comercial y para explicarle el sistema a un
cliente.

---

## 1. Qué es Chasqui

Chasqui es un **analista para el dueño de un negocio pequeño** —una tienda de
barrio, una ferretería, un minimercado— que trabaja **por Telegram**. El tendero
le manda sus facturas de compra y su reporte de ventas, y Chasqui le devuelve, en
minutos, un informe claro de dónde está ganando y dónde está perdiendo plata.

No es un contador ni un ERP. Es un asistente que responde una pregunta que el
tendero casi nunca puede contestar solo: **"¿qué productos me están dejando poco
margen, cuáles subieron de costo y no ajusté el precio, y cuáles se me van a
acabar?"**

El bot es **@chasqui_alunabot**.

---

## 2. El problema que resuelve

El tendero promedio:

- **No sabe su margen real por producto.** Sabe cuánto vende, no cuánto le queda.
- **No nota cuándo le suben un costo.** El proveedor sube el precio del aceite y
  él sigue vendiéndolo al mismo precio de antes, perdiendo en cada unidad.
- **No sabe qué productos concentran su ganancia** (típicamente pocos productos
  hacen la mayoría de la utilidad — el principio de Pareto).
- **Se queda sin stock de lo que más rota** sin darse cuenta a tiempo.

La frase que resume el valor: *un bot que conversa bien y calcula mal es el
fracaso más caro, porque no se nota hasta que el cliente sube el precio
equivocado.* Por eso Chasqui **nunca inventa una cifra**: el modelo de lenguaje
redacta, pero cada número del informe se verifica contra los datos reales antes
de enviarlo.

---

## 3. Servicios disponibles

Chasqui es un **catálogo de servicios de análisis**. Hoy hay uno; se agregan más
sin reprogramar el bot.

### Análisis de ventas y compras *(activo)*

Cruza lo que el negocio **compró** contra lo que **vendió** y devuelve, para cada
problema, cuánta plata cuesta y qué hacer:

1. **Costo al alza** — cuánto más te cuesta al mes, en cuánto te queda el margen
   y a qué precio deberías vender para recuperarlo.
2. **Proveedor más caro** — le estás pagando a uno más de lo que ya te cobró
   otro por lo mismo, y cuánto ahorrás cambiando.
3. **Margen bajo** — cuánta utilidad no estás ganando y a qué precio llegar.
4. **Se agota** — cuántas unidades pedir, contando lo que demora el proveedor.
5. **Plata quieta** — cuánto capital tenés dormido en lo que no rota.
6. **Dependencia de un proveedor** — cuando uno solo concentra las compras.

### Mercado de compras *(activo)*

Para quien solo tiene facturas de compra: dónde se va la plata, qué costos se
dispararon, qué producto le cuesta muy distinto según a quién le compre y cuánto
pesa cada proveedor.

### Servicios futuros *(ejemplos que caben sin tocar el motor)*

- **Consumo de servicios públicos** — recibos + medidores.
- Cualquier análisis que siga el patrón: recibir archivos → normalizar →
  analizar → entregar informe.

---

## 4. Cómo se usa (paso a paso, desde el lado del tendero)

**El usuario casi no escribe.** Cada mensaje del bot trae los botones de lo que
puede hacer a continuación, así que el único "tecleo" real es adjuntar los
archivos. Menos tecleo = menos errores.

```
Usuario: /start                                    (o toca Iniciar)
Chasqui: ¡Hola! 👋 Soy Chasqui, un asistente para tu negocio.
         Contame qué tenés en mente y te ayudo con lo que sepa. Y si preferís,
         puedo revisar tus números…
         [🔎 ¿Qué puedo hacer?]

Usuario: (toca 🔎 ¿Qué puedo hacer?)
Chasqui: Esto es lo que puedo hacer por ahora:
         [Análisis de ventas y compras]
         [Mercado de compras]
         [❓ Cómo funciona]
         [⬅️ Volver]

Usuario: (toca Análisis de ventas y compras)
Chasqui: Antes de arrancar, contame: ¿qué tipo de negocio es?
         [🛒 Minimercado o tienda]
         [🏬 Almacén o punto de venta]
         [🚚 Distribuidora o mayorista]
         [🍽️ Restaurante o cafetería]
         [🏷️ Otro]

Usuario: (toca 🛒 Minimercado o tienda)
Chasqui: Listo: Análisis de ventas y compras.
         Mandame los archivos de facturación de tu negocio: las ventas y las
         compras. De dónde salgan no me importa, y tampoco cómo se llamen las
         columnas: yo los leo.
         📅 Con 3 meses ya sale un análisis serio. Entre más me mandes, mejor.
         [✖️ Cancelar]

Usuario: [adjunta factura1.xml]
Chasqui: ✅ Leí factura1.xml: 4 registros del 2026-07-17, 4 productos,
         $502.744 en total.
         [📊 Analizar]
         [✖️ Cancelar]

Usuario: [adjunta ventas_julio.csv]
Chasqui: ✅ Leí ventas_julio.csv: 17 registros del 1 al 31 de julio,
         4 productos, $1.245.900 en total.
         [📊 Analizar]
         [✖️ Cancelar]

Usuario: (toca 📊 Analizar)
Chasqui: ⏳ Estoy analizando tu información. Te aviso apenas esté el informe.
         …
         (el informe, ver §6)
         [🔄 Analizar otra vez]
```

**El primer mensaje no pide nada y no vende nada**: presenta a Chasqui e invita
a escribirle. Esa es la puerta principal —cualquier pregunta sobre el negocio se
contesta con lo que haya cargado—, y el menú de análisis queda a un botón de
distancia para quien lo busque.

**La naturaleza del negocio se pregunta una sola vez.** Un 18% de margen es
normal en una distribuidora y flojo en un minimercado: sin ese dato el análisis
compara contra un promedio que no existe.

Si el usuario adjunta un archivo sin haber empezado nada, Chasqui abre el
análisis solo y lo procesa, en vez de pedirle que arranque de cero y lo reenvíe.

### La conversación en una imagen

```
/start ──► [¿Qué puedo hacer?] ──► [análisis] ──► tipo de negocio ──►
           adjuntar archivos ──► [📊 Analizar] ──► informe
```

Todo lo que se puede tocar se puede también escribir (`/nueva`, `/listo`,
`/cancelar`), y el botón ☰ del menú de Telegram tiene esos mismos comandos para
cuando alguien se pierde. Los botones de mensajes viejos siguen funcionando: si ya
no aplican, Chasqui responde algo con sentido en vez de "no te entendí".

---

## 5. Qué archivos acepta

| Archivo | Qué es | De dónde sale |
|---|---|---|
| **XML de la DIAN** | Factura electrónica de venta (lo que le facturan al negocio sus proveedores). | El correo que le llega de cada proveedor. Puede venir dentro de un `.zip` junto al PDF. |
| **CSV del POS** | El listado de ventas de su caja registradora / software de punto de venta. | Exportar desde su POS. Columnas típicas: fecha, producto, categoría, cantidad, precio, total. |

- Puede enviar **varias facturas** en un mismo lote.
- Si un archivo llega dañado o ilegible, Chasqui **procesa el resto** y le avisa
  cuál revisar. Nunca pierde todo el lote por un archivo malo.
- Chasqui **no necesita fotos**: el modelo no ve imágenes, todo el trabajo pesado
  es sobre los datos, no sobre escaneos.

---

## 6. Qué entrega

Un informe **en el chat**, con lenguaje humano y pensado para el dueño, no para un
contador. No hay PDF que abrir: se lee de una, en el teléfono. Salida real:

```
📊 Análisis de ventas y compras
del 1 de febrero al 31 de julio de 2026

📦 Productos analizados: 26
💰 Margen promedio: 29,84 %
📈 Con costo al alza: 1
🕐 Se agotan pronto: 20
🏆 Concentran la ganancia: 11

🩺 Salud del negocio
🔴 Ventas     ████░░░░░░  38
🟢 Márgenes   ██████████ 100
🔴 Inventario ██░░░░░░░░  23
🟢 Compras    ██████████  96
🟡 Riesgos    ████████░░  76

Índice general: 67/100

Te estás quedando sin lo que más vendés

🕐 YOGURT ALPINA 1L
Te alcanza para 1,7 días y vendés 3 unidades por día.
💸 Si te quedás sin producto, son unos $102.000 que dejás de vender
   mientras llega el pedido.
✓ Pedí 21 unidades: es lo que vendés en los 4 días que demora el
  proveedor más 3 días de colchón.
✓ Si el proveedor demora más de lo normal, pedí antes, no más cantidad.
🔴 Prioridad alta

📈 PANELA CUADRADA 500G
El costo pasó de $1.900 a $2.100: subió 10,53% desde tu primera compra.
Con tu precio de venta actual el margen te queda en 25%.
💸 Al ritmo que lo comprás, son unos $1.000 más al mes.
✓ Negociá el precio con tu proveedor antes de la próxima compra.
✓ Comprale a Distribuidora Sur, que te lo dejó a $1.850.
🟢 Prioridad baja

✅ Qué hacer esta semana
1. Hacé el pedido de yogurt hoy: te quedan menos de dos días.
2. Llamá al proveedor de la panela antes de la próxima compra.

Las cifras y los cálculos salen de los archivos que me mandaste.
Si alguna no te cuadra, decime y la reviso.
```

Cada problema contesta cuatro preguntas, en este orden: **qué pasó**, **cuánta
plata es**, **qué opciones tenés** y **qué tan urgente es**. Esa es la diferencia
entre un dato ("el costo subió 10,53%") y una decisión.

Lo que ve el usuario como redacción lo escribe el modelo de lenguaje, pero **el
impacto en pesos, el precio sugerido, la cantidad a pedir y el proveedor más
barato los calcula el sistema**, no el modelo. Si el modelo llegara a inventar
una cifra, el informe no se envía: se rehace, y si vuelve a fallar sale la
versión sin redactar —que trae exactamente los mismos números y las mismas
recomendaciones, solo que más seca—.

El **índice de salud** de arriba es un resumen de cinco frentes en una escala de
0 a 100, y tampoco pasa por la IA. Una nota solo aparece si hay datos para
calcularla: si el negocio no cargó ventas, no hay nota de ventas.

Si el informe es largo, llega partido en varios mensajes, cortado por secciones
completas: nunca a mitad de una frase.

---

## 7. Comandos

Los comandos **no son la vía principal**: cada paso llega con sus botones, y estos
mismos comandos están en el menú del botón azul de Telegram. Están para quien
prefiera escribir, o para salir de un atasco.

### Para cualquier usuario

| Comando | Botón equivalente | Qué hace |
|---|---|---|
| `/start`, `/ayuda` | ⬅️ Volver | Bienvenida. |
| `/nueva` | — | Empieza un análisis nuevo (cierra el que estuviera a medias). |
| `/portal` | — | Enlace de un uso al portal web. |
| `/listo` | 📊 Analizar | Cierra el envío de archivos y dispara el análisis. |
| `/cancelar` | ✖️ Cancelar | Cancela el análisis en curso. Los archivos ya enviados quedan guardados. |
| `/comofunciona` | ❓ Cómo funciona | Los tres pasos, en corto. |
| `/privacidad` | 🔒 Qué datos uso | Qué se guarda, qué sale y qué no. |

Tocar **✅ Acepto** (o escribir "acepto") la primera vez autoriza el tratamiento de
los datos del negocio, requisito legal antes de procesar nada. Antes de aceptar
igual se puede consultar 🔒 Qué datos uso.

### Para el administrador (dueño de la operación)

Restringidos por rol; un usuario normal no los ve. Se responden en el mismo chat.

| Comando | Qué muestra |
|---|---|
| `/salud` | Estado de la ingesta de archivos: cuántos entran, cuántos fallan por tipo. |
| `/embudo` | Dónde abandona la gente: iniciadas, completadas, abandonadas, en qué paso se caen. |
| `/fallas` | Errores de las últimas 24 horas. |
| `/consumo` | Tokens y costo del mes por negocio. |
| `/matching` | Calidad del reconocimiento de productos: % resuelto, pendientes. |

`/embudo` es el más valioso durante la validación con clientes: dice en qué paso
exacto se cae la gente, que es la única forma de saber si el problema es el
servicio o la conversación.

---

## 8. Cómo reconoce los productos

El mismo producto aparece escrito distinto en la factura ("ARROZ DIANA 500G") y en
la caja ("Arroz Diana x500"). Chasqui los une así:

- Las **facturas de la DIAN traen código de barras**, que es una identificación
  exacta. Con ellas Chasqui **arma el catálogo** del negocio.
- Las **ventas del POS**, que no traen código, se emparejan por **parecido de
  nombre** contra ese catálogo.
- Lo que no logra emparejar con confianza queda **pendiente de confirmar**, no se
  adivina. Así los cálculos nunca se hacen sobre datos inventados.

Esto significa que **los primeros análisis mejoran con el uso**: cuantas más
facturas entran, más completo queda el catálogo y mejor emparejan las ventas.

---

## 8.bis El inventario: contado o estimado, pero siempre dicho

Chasqui no sabe con qué mercancía arrancó el negocio. Mientras nadie le pase un
conteo, calcula el stock como **lo comprado menos lo vendido** — que sirve para
orientarse, pero no es el stock real de la bodega.

Eso importa porque de ese número salen dos de las seis alertas: *"se te va a
agotar"* y *"tenés plata quieta"*. Con un stock mal estimado, esas dos
recomendaciones pueden ser exactamente al revés de lo que conviene.

Por eso, cuando el stock es estimado, **el informe lo dice**: la nota de
Inventario lleva un asterisco con su aclaración, y cada recomendación que
dependa del stock agrega *"Ojo: es una estimación de lo comprado menos lo
vendido, no un conteo tuyo"*.

**Cómo se arregla**: contando. Dos vías, y ninguna pide contar todo:

- **En el portal**, pestaña Ventas → Inventario: la lista de productos con su
  stock y un botón *Contar* al lado de cada uno.
- **Con un archivo** de conteo (producto, unidades, fecha), por el mismo camino
  que las ventas y las compras.

Desde el conteo en adelante Chasqui sigue la cuenta solo: suma lo que se compra
y resta lo que se vende. No hace falta volver a contar cada semana.

---

## 9. Umbrales configurables por negocio

Un tendero de barrio y una ferretería no tienen los mismos criterios. Cada negocio
puede tener sus propios umbrales (si no, usa unos por defecto):

| Umbral | Default | Qué controla |
|---|---|---|
| Margen mínimo | 15% | Debajo de esto, el producto se marca como "margen bajo". |
| Días de cobertura mínimos | 7 | Debajo de esto, "se va a agotar pronto". |
| Alerta de deriva de costo | 10% | Si el costo se movió más que esto, se reporta. |
| Rotación baja | 30 días | Marca productos que casi no se mueven. |

---

## 10. Planes, límites y costo

### El plan gratuito cubre una ventana de historia

El plan gratuito analiza los **últimos 3 meses**. Lo que el usuario mande de
antes **se guarda igual**: no se analiza todavía, pero está adentro. Si amplía
el plan, esa historia entra al análisis sola, sin volver a mandar un archivo.

Es una diferencia que importa dos veces. Para el usuario, porque nadie le pide
que vuelva a subir un año de facturas justo después de pagar. Y para Chasqui,
porque un sistema que dice conocer el negocio no puede borrarle el pasado por su
plan de precios: sin historia no hay "esto mejoró", ni "hace tres meses lo
comprabas más barato", ni comparación contra el mismo mes del año anterior.

Cuando quedan registros fuera de la ventana, el bot lo dice al terminar la
carga: cuántos son, y que están guardados esperando.

### Cupo de análisis

Cada análisis consume recursos del modelo de lenguaje. Cada negocio tiene un
**cupo mensual**. Si lo supera:

- Chasqui **no ejecuta** el análisis (no gasta de más).
- El usuario recibe: *"Tu negocio superó el cupo mensual de análisis. Se renueva
  el [fecha]."*

El control se hace **antes** de gastar, no después, para no descubrir el desborde
en la factura del proveedor.

---

## 11. Qué pasa cuando algo falla (desde el lado del usuario)

El sistema está hecho para que el usuario **nunca vea un error técnico**:

| Situación | Lo que ve el tendero |
|---|---|
| Un archivo llegó dañado | "Procesé 3 de 4 archivos, revisa factura_2.xml". El resto sigue. |
| El análisis se cayó a mitad | En pocos minutos: "Algo salió mal generando tu informe. Ya quedé avisado." No queda esperando para siempre. |
| Dejó el análisis a medias | A las 24 h: un recordatorio único para retomarlo. |
| El modelo intentó inventar una cifra | Recibe el informe con datos ciertos, sin la narración dudosa. |

Detrás, cada falla queda registrada y el administrador recibe el detalle técnico
por su chat. El tendero solo ve lenguaje humano.

---

## 12. Privacidad

- La identidad del usuario es su **cuenta de Telegram**; no hay contraseñas.
- Antes de procesar cualquier dato, el usuario **autoriza explícitamente** el
  tratamiento (escribiendo "acepto"), y queda registrada la fecha.
- Los datos del negocio (facturas, ventas, informes) son de ese negocio; el
  sistema los guarda para poder darle continuidad al servicio y sus análisis.

---

## 13. Por qué está construido así (para no-técnicos)

Todo el "cerebro" de Chasqui —los textos, las reglas, los umbrales, la forma de
redactar los informes, qué servicios existen— vive en una **base de datos**, no
en el programa. Consecuencia práctica para el negocio:

- **Lanzar un servicio nuevo o cambiar el tono de los informes de los 40 clientes
  es un cambio de configuración, no una reprogramación.** Se hace en minutos y sin
  riesgo de romper lo que ya funciona.
- El sistema aguanta decenas de servicios sin volverse un enredo.
- Si algo se pierde, la base de datos es la copia de seguridad de todo el negocio.
