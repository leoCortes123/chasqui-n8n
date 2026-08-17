# Guía funcional — Chasqui

Qué hace Chasqui, para quién, y **cómo se usa paso a paso**. Está escrita para
que un dueño de negocio pueda usar el sistema sin que nadie se lo explique, y
para que producto y comercial puedan contarlo sin entrar en la técnica.

Si solo querés empezar, andá al §3 (*Arranque en cinco minutos*).

---

## 1. Qué es Chasqui

Chasqui es un **analista de negocio que trabaja por chat**. El dueño le manda sus
facturas de compra y su reporte de ventas, y Chasqui le devuelve, en minutos, un
informe claro de dónde está ganando y dónde está perdiendo plata — y después
sigue el hilo: le avisa cuando algo se pone urgente, le responde preguntas sobre
sus propios números y le mide si la recomendación que aplicó sirvió.

El bot es **@chasqui_alunabot** en Telegram. Hay además un **portal web** (§10)
donde se ve todo con más detalle.

**Para quién es.** Para negocios pequeños y medianos que **ya tienen sus números
en digital**: un POS que exporta ventas, facturas electrónicas de sus
proveedores, o al menos una planilla. No es para el negocio que no lleva
registros — Chasqui analiza datos, no los inventa.

No es un contador ni un ERP. Es un asistente que responde una pregunta que el
dueño casi nunca puede contestar solo: **"¿qué productos me están dejando poco
margen, cuáles subieron de costo y no ajusté el precio, y cuáles se me van a
acabar?"**

---

## 2. El problema que resuelve

El dueño promedio:

- **No sabe su margen real por producto.** Sabe cuánto vende, no cuánto le queda.
- **No nota cuándo le suben un costo.** El proveedor sube el precio del aceite y
  él sigue vendiéndolo al mismo precio, perdiendo en cada unidad.
- **No sabe qué productos concentran su ganancia** (típicamente pocos productos
  hacen la mayoría de la utilidad — el principio de Pareto).
- **Se queda sin stock de lo que más rota** sin darse cuenta a tiempo.
- **No se acuerda de qué le dijeron el mes pasado**, ni si lo que hizo funcionó.

La frase que resume el valor: *un bot que conversa bien y calcula mal es el
fracaso más caro, porque no se nota hasta que el cliente sube el precio
equivocado.* Por eso Chasqui **nunca inventa una cifra**: el modelo de lenguaje
redacta, pero cada número del informe se verifica contra los datos reales antes
de enviarlo.

---

## 3. Arranque en cinco minutos

**El usuario casi no escribe.** Cada mensaje del bot trae los botones de lo que
puede hacer a continuación, así que el único "tecleo" real es adjuntar los
archivos.

1. **Abrí el bot** en Telegram: `@chasqui_alunabot`, y tocá *Iniciar* (o escribí
   `/start`). La bienvenida trae un solo botón: **🔎 ¿Qué puedo hacer?**.
2. Tocalo y elegí **Análisis de ventas y compras**.
3. **Ahí aparece el permiso**: Chasqui explica qué hace, avisa que el análisis lo
   produce una inteligencia artificial y puede equivocarse, y espera que toques
   **✅ Acepto y continúo**. Antes de aceptar podés leer 🔐 *Cómo trato tus
   datos*. Es un requisito legal: sin aceptar no se procesa nada.
   *El permiso se pide acá, no al arrancar — también sale si en vez de tocar
   botones le escribís directamente una pregunta sobre tu negocio.*
4. **Decí qué tipo de negocio es** (minimercado, distribuidora, restaurante…).
   Se pregunta una sola vez.
5. **Adjuntá tus archivos**: el CSV/Excel de ventas de tu POS y las facturas XML
   de tus proveedores. Podés mandar varios, uno tras otro. Chasqui te confirma
   cada uno con lo que entendió ("leí 17 registros del 1 al 31 de julio").
6. Tocá **📊 Analizar**. En unos minutos llega el informe al chat.

Con **3 meses** de datos ya sale un análisis serio. Entre más historia mandes,
mejor: las comparaciones ("venís cayendo", "el año pasado vendías más") necesitan
pasado.

### La conversación, en una línea

```
/start ──► [¿Qué puedo hacer?] ──► [Análisis de ventas y compras] ──►
           tipo de negocio ──► adjuntar archivos ──► [📊 Analizar] ──► informe
```

Todo lo que se puede tocar se puede también escribir (`/nueva`, `/listo`,
`/cancelar`), y el botón ☰ del menú de Telegram tiene esos mismos comandos para
cuando alguien se pierde. Los botones de mensajes viejos siguen funcionando: si
ya no aplican, Chasqui responde algo con sentido en vez de "no te entendí".

**Los menús no llenan el chat**: al navegar entre pantallas —abrir el menú,
entrar a una opción, volver— el mismo mensaje se va actualizando en su lugar en
vez de mandar uno nuevo. Lo que sí queda como mensaje propio es lo que vale la
pena conservar: los informes, las confirmaciones de cada archivo y el resultado
de cada acción.

Si adjuntás un archivo sin haber empezado nada, Chasqui abre el análisis solo y
lo procesa, en vez de pedirte que arranques de cero y lo reenvíes.

---

## 4. Qué archivos acepta

| Archivo | Qué es | De dónde sale |
|---|---|---|
| **XML de la DIAN** | Factura electrónica de compra (lo que te facturan tus proveedores). | El correo que te llega de cada proveedor. Puede venir dentro de un `.zip` junto al PDF. |
| **Tabla de ventas** (CSV, XLS, XLSX, ODS) | El listado de ventas de tu caja registradora o software de punto de venta. | Exportar desde tu POS. Columnas típicas: fecha, producto, categoría, cantidad, precio, total. |
| **Conteo de inventario** (tabla) | Producto, unidades y fecha. Opcional, ver §8. | A mano o exportado de tu sistema. |

**No importa cómo se llamen las columnas.** La primera vez que Chasqui ve un
formato de POS nuevo aprende cómo está armado y lo recuerda; los archivos
siguientes de ese mismo POS entran sin volver a pensarlo.

- Podés enviar **varias facturas** en un mismo lote.
- Si un archivo llega dañado o ilegible, Chasqui **procesa el resto** y te avisa
  cuál revisar. Nunca se pierde todo el lote por un archivo malo.
- **No manda fotos ni escaneos**: Chasqui trabaja sobre datos, no sobre imágenes.
- Subir dos veces el mismo archivo **no duplica** nada.

---

## 5. Servicios disponibles

Chasqui es un **catálogo de servicios de análisis**. Se agregan más sin
reprogramar el bot.

### Análisis de ventas y compras *(activo)*

Cruza lo que el negocio **compró** contra lo que **vendió** y devuelve, para cada
problema, cuánta plata cuesta y qué hacer. Las once reglas de hoy:

| Lo que detecta | Qué te dice |
|---|---|
| **Costo al alza** | Cuánto más te cuesta al mes, en cuánto te queda el margen y a qué precio deberías vender para recuperarlo. |
| **Proveedor más caro** | Le estás pagando a uno más de lo que ya te cobró otro por lo mismo, y cuánto ahorrás cambiando. |
| **Margen bajo** | Cuánta utilidad no estás ganando y a qué precio llegar. |
| **Se agota** | Cuántas unidades pedir, contando lo que demora el proveedor. |
| **Plata quieta** | Cuánto capital tenés dormido en lo que no rota. |
| **Dependencia de un proveedor** | Cuando uno solo concentra tus compras. |
| **Dejó de venderse** | Un producto que tenía ritmo y lleva mes y medio sin una venta. |
| **El proveedor viene subiendo** | El mismo proveedor te subió el precio tres veces o más en el último año. |
| **El margen se viene cayendo** | Tres mediciones en bajada, no un mal mes suelto. |
| **Vendés menos que el año pasado** | El último mes completo contra el mismo mes del año anterior. |
| **Te deben y ya venció** | Un cliente con saldo vencido: plata tuya que está en la calle. |

Las cuatro comparativas (las que miran la película y no la foto) necesitan
historia: aparecen a medida que Chasqui acumula meses de datos tuyos.

### Mercado de compras *(activo)*

Para quien solo tiene facturas de compra: dónde se va la plata, qué costos se
dispararon, qué producto te cuesta muy distinto según a quién le compres y cuánto
pesa cada proveedor.

### Consultas sobre tus números *(activo)*

No es un botón: es escribirle. Ver §7.

---

## 6. El informe: cómo se lee

Llega **en el chat**, en lenguaje humano y pensado para el dueño, no para un
contador. No hay PDF que abrir: se lee de una, en el teléfono.

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
🟢 Liquidez   █████████░  98

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

**Cómo se ordena.** No gana el número más grande, gana lo que más pesa para *tu*
negocio. Un problema que te cuesta plata todos los meses, uno que te cuesta una
sola vez, y capital que está inmovilizado no son la misma cosa, y cada uno se
compara contra lo que tu negocio mueve en un mes. Por eso $100.000 dormidos en
arroz pueden quedar por debajo de un yogurt que se te agota mañana.

**El índice de salud** de arriba resume seis frentes en una escala de 0 a 100 y
**no pasa por la IA** en ningún momento. Una nota solo aparece si hay datos para
calcularla: si no cargaste ventas, no hay nota de ventas; si vendés todo de
contado, no hay nota de liquidez (y eso no te baja el índice).

**Quién escribe qué.** La redacción la hace el modelo de lenguaje, pero **el
impacto en pesos, el precio sugerido, la cantidad a pedir y el proveedor más
barato los calcula el sistema**. Si el modelo llegara a inventar una cifra, el
informe no se envía: se rehace, y si vuelve a fallar sale la versión sin redactar
—los mismos números y las mismas recomendaciones, solo que más seca—.

Si el informe es largo, llega partido en varios mensajes, cortado por secciones
completas: nunca a mitad de una frase.

---

## 7. Preguntarle a Chasqui

Escribile la pregunta como se te ocurra. Responde con **tus** números, no con
generalidades. Ocho preguntas están cubiertas de punta a punta:

| Preguntá algo como… | Te contesta |
|---|---|
| "¿cuánto vendí en marzo?" | Ventas del periodo, con unidades, y la comparación contra el mismo mes del año pasado si hay con qué. |
| "¿cuánto le compré a Mayorista Centro?" | Compras del periodo, filtrando por proveedor o producto. |
| "¿a qué proveedor le compro más?" | El gasto repartido por proveedor. |
| "¿qué producto me deja más plata?" | El más rentable, con la utilidad que dejó. |
| "¿dónde estoy dejando poco margen?" | Los productos por debajo de tu margen mínimo. |
| "¿a qué le subió el costo?" | Los productos que se encarecieron y desde cuándo. |
| "¿qué se me está agotando?" / "¿qué está quieto?" | Cobertura y stock, con la aclaración de si el stock es contado o estimado. |
| "¿cómo está mi negocio y qué hago primero?" | El índice de salud, el comparativo contra la vez pasada y lo más urgente que tenés abierto. |

Dos cosas que conviene saber:

- **Si no hay datos de ese periodo, lo dice.** "No tengo datos de entonces" no es
  lo mismo que "vendiste $0", y Chasqui no confunde una cosa con la otra.
- **La ventana temporal la mandás vos.** "En junio", "el mes pasado", "este año".
  Si no decís nada, usa el periodo por defecto de esa pregunta.

Para lo que no está en los números, podés **enseñarle**: `/saber <lo que sea>`
guarda un dato tuyo (un precio, una condición de un proveedor, un horario) y lo
usa en las respuestas siguientes. Todo eso se ve y se edita en el portal,
pestaña **Conocimiento**.

---

## 8. Actuar sobre lo que te recomienda

Una recomendación no es un renglón: es algo que Chasqui te dijo y que va a
seguir. Al final de cada informe hay un botón **✅ Ya hice algo** que abre la
lista de lo que tenés pendiente.

Sobre cada una podés:

| Botón | Qué pasa |
|---|---|
| **✅ Ya lo hice** | Se cierra. Chasqui lo revisa en el próximo análisis para ver si los números lo confirman. |
| **⏭️ No aplica** | Se saca de la lista. Si el problema vuelve a aparecer te lo dice de nuevo, pero no insiste con ese. |
| **💲 Aplicar $X** | Guarda el precio sugerido en tu lista de precios del portal. **No cambia el precio en tu punto de venta** — eso lo hacés vos. Solo aparece cuando hay un precio concreto que aplicar. |

Lo mismo se puede hacer desde el portal, pestaña **Informes → Lo que te vengo
diciendo**, donde además ves desde cuándo está abierta cada una y cuántas veces
te la dijo.

**¿Sirvió?** Cuando cerrás una recomendación, Chasqui se guarda cómo estaba el
número en ese momento. Cuando entran datos nuevos lo vuelve a mirar y te dice si
mejoró, empeoró o quedó igual. Si todavía no entraron datos nuevos, dice **"sin
medir todavía"** en vez de inventar un resultado.

**La lista de compra.** Todo lo que está por agotarse se consolida en el portal
(**Informes → Lo que habría que comprar**): producto, cuántas unidades, el
proveedor más barato **al que ya le compraste** y el costo estimado. Si de algún
producto no conoce precio, no lo mete al total y lo dice — un total al que le
faltan renglones no es el total de la compra.

---

## 9. Chasqui habla primero

No hace falta pedirle todo.

**Avisos cuando algo urge.** Si cargaste datos nuevos y aparece algo de prioridad
alta, te llega un mensaje corto con el hallazgo y dos botones (ver el análisis
completo, o marcar que ya hiciste algo). Las reglas del aviso están hechas para
**no molestar**:

- solo prioridad alta;
- **un** aviso por vez, nunca una ráfaga;
- el mismo problema no se repite dentro de dos semanas;
- solo entre las 8 y las 20;
- solo si entraron datos nuevos desde tu último análisis.

**Informe mensual automático.** Si pasó un mes desde tu último análisis y desde
entonces cargaste datos, Chasqui te manda un aviso corto y a continuación el
informe, esta vez comparado con cómo venías. Nunca se lo manda a quien todavía no
vio ningún informe: el primero lo pedís vos. Si no lo querés, decílo por el chat
y se apaga para tu negocio (hoy es un parámetro que ajusta soporte, no un botón).

---

## 10. El portal web

En el chat está lo importante; en el portal está **todo**.

**Cómo entrar**: escribí `/portal` en el chat. Llega un enlace que sirve **una
sola vez** y vence a los 15 minutos. No hay usuario ni contraseña: la identidad
es tu cuenta de Telegram. Si se venció, pedí otro.

| Pestaña | Qué hay |
|---|---|
| 🏪 **Mi negocio** | Lo que Chasqui sabe de vos: qué vendés, a quién le comprás, tu margen típico, cuándo vendés más, qué problemas se repiten. Consumo del mes y calidad de los datos. **Revisalo**: si dice que tu proveedor principal es uno que casi no usás, hay algo mal cargado. |
| 📈 **Ventas** | Ventas del mes, mes a mes, lo que más se vende, **cartera** (quién te debe, y el botón para anotar una deuda a mano), **inventario** con el botón *Contar*, **productos sin resolver**, últimos movimientos y archivos subidos. |
| 🏷️ **Precios** | Tu lista de precios y las cotizaciones que armes (se pueden compartir por enlace). |
| 💡 **Conocimiento** | Lo que le enseñaste al bot y las preguntas que no supo responder. |
| 📊 **Informes** | Lo que te viene diciendo y qué se cerró, la lista de compra, cómo viene tu negocio mes a mes y los informes anteriores completos. |

---

## 11. El inventario: contado o estimado, pero siempre dicho

Chasqui no sabe con qué mercancía arrancó tu negocio. Mientras nadie le pase un
conteo, calcula el stock como **lo comprado menos lo vendido** — sirve para
orientarse, pero no es el stock real de la bodega.

Eso importa porque de ese número salen dos alertas: *"se te va a agotar"* y
*"tenés plata quieta"*. Con un stock mal estimado, esas dos recomendaciones
pueden ser exactamente al revés de lo que conviene.

Por eso, cuando el stock es estimado, **el informe lo dice**: la nota de
Inventario lleva un asterisco y cada recomendación que dependa del stock agrega
*"Ojo: es una estimación de lo comprado menos lo vendido, no un conteo tuyo"*.

**Cómo se arregla**: contando. Dos vías, y ninguna pide contar todo:

- **En el portal**, pestaña Ventas → Inventario: la lista de productos con su
  stock y un botón *Contar* al lado de cada uno.
- **Con un archivo** de conteo (producto, unidades, fecha), por el mismo camino
  que las ventas y las compras.

Desde el conteo en adelante Chasqui sigue la cuenta solo: suma lo que comprás y
resta lo que vendés. No hace falta volver a contar cada semana.

---

## 12. Cómo reconoce los productos (y qué hacer con los que no reconoce)

El mismo producto aparece escrito distinto en la factura ("ARROZ DIANA 500G") y
en la caja ("Arroz Diana x500"). Chasqui los une así:

- Las **facturas de la DIAN traen código de barras**, que es una identificación
  exacta. Con ellas **arma el catálogo** de tu negocio.
- Las **ventas del POS**, que no traen código, se emparejan por **parecido de
  nombre** contra ese catálogo.
- Lo que no logra emparejar con confianza queda **pendiente de confirmar**, no se
  adivina. Así los cálculos nunca se hacen sobre datos inventados.

**Una línea sin producto no entra a ningún cálculo**: no tiene margen, no tiene
rotación, no aparece en el Pareto ni en ninguna recomendación.

Eso importa por una razón concreta: el porcentaje de productos reconocidos
engaña. *"85% resuelto"* suena bien, pero si lo que quedó fuera es justo lo que
más se vende, puede ser la mitad de la facturación la que no se está analizando.

Por eso el portal (**Ventas → Productos sin resolver**) encabeza con la plata:
*"$X en N movimientos no entran a ningún cálculo"*. Debajo, cada texto sin
resolver con el producto que Chasqui cree que es —se puede cambiar— y un botón
para confirmarlo. **Al confirmar, los movimientos viejos se recuperan solos**:
todas las líneas que decían lo mismo pasan a contar desde ese momento.

Consecuencia práctica: **los primeros análisis mejoran con el uso**. Cuantas más
facturas entran, más completo queda el catálogo y mejor emparejan las ventas.

---

## 13. Comandos

Los comandos **no son la vía principal**: cada paso llega con sus botones, y
estos mismos comandos están en el menú del botón azul de Telegram. Están para
quien prefiera escribir, o para salir de un atasco.

### Para cualquier usuario

| Comando | Botón equivalente | Qué hace |
|---|---|---|
| `/start`, `/ayuda` | ⬅️ Volver | Bienvenida. |
| `/nueva` | — | Empieza un análisis nuevo (cierra el que estuviera a medias). |
| `/listo` | 📊 Analizar | Cierra el envío de archivos y dispara el análisis. |
| `/cancelar` | ✖️ Cancelar | Cancela el análisis en curso. Los archivos ya enviados quedan guardados. |
| `/portal` | — | Enlace de un uso al portal web. |
| `/plan` | — | Tu plan, la ventana de historia que analiza y el cupo del mes. |
| `/saber <dato>` | — | Le enseña algo que no está en los archivos. |
| `/comofunciona` | ❓ Cómo funciona | Los tres pasos, en corto. |
| `/privacidad` | 🔒 Qué datos uso | Qué se guarda, qué sale y qué no. |

Tocar **✅ Acepto y continúo** (o escribir "acepto") la primera vez autoriza el
tratamiento de los datos del negocio, requisito legal antes de procesar nada. El
permiso se pide al elegir el primer servicio o al hacer la primera pregunta, no
en la bienvenida, y el paso que lo disparó se retoma solo al aceptar.

### Para el administrador (dueño de la operación)

Restringidos por rol; un usuario normal no los ve. Se responden en el mismo chat.

| Comando | Qué muestra |
|---|---|
| `/salud` | Estado de la ingesta de archivos: cuántos entran, cuántos fallan por tipo. |
| `/embudo` | Dónde abandona la gente: iniciadas, completadas, abandonadas, en qué paso se caen. |
| `/fallas` | Errores de las últimas 24 horas. |
| `/consumo` | Tokens y costo del mes por negocio. |
| `/matching` | Calidad del reconocimiento de productos: **cuánta plata queda fuera de los cálculos** por no tener producto resuelto, y el % de aliases resuelto. |
| `/pendientes` | Los productos sin resolver, con su mejor candidato y cuánto dinero representan. |

`/embudo` es el más valioso durante la validación con clientes: dice en qué paso
exacto se cae la gente, que es la única forma de saber si el problema es el
servicio o la conversación.

---

## 14. Umbrales configurables por negocio

Un minimercado y una ferretería no tienen los mismos criterios. Cada negocio
puede tener sus propios umbrales (si no, usa los de defecto):

| Umbral | Default | Qué controla |
|---|---|---|
| Margen mínimo | 15 % | Debajo de esto, el producto se marca como "margen bajo". |
| Días de cobertura mínimos | 7 | Debajo de esto, "se va a agotar pronto". |
| Alerta de deriva de costo | 10 % | Si el costo se movió más que esto, se reporta. |
| Rotación lenta | 30 días | Marca productos que casi no se mueven. |
| Días sin venta | 45 | Un producto con ritmo que lleva más que esto sin venderse. |
| Subidas del proveedor | 3 al año | Cuántas subidas seguidas encienden la alerta. |
| Caída de margen | 3 puntos | Cuánto tiene que bajar el margen para avisar. |
| Caída contra el año pasado | 15 % | Cuánto puede caer el mes antes de avisar. |
| Mora de cartera | 15 días | Desde cuándo una factura cuenta como vencida. |
| Días entre informes automáticos | 30 | Cada cuánto puede llegar el informe sin pedirlo. |
| Silencio entre avisos iguales | 14 días | El mismo problema no se avisa dos veces seguidas. |
| Horario de avisos | 8 a 20 | Fuera de ese rango no se manda nada. |

Los umbrales quedan registrados en cada análisis: si una nota de salud baja
porque alguien cambió un umbral, eso no es un deterioro del negocio y Chasqui
puede distinguirlo.

---

## 15. Planes, límites y costo

### El plan gratuito cubre una ventana de historia

El plan gratuito analiza los **últimos 3 meses**. Lo que mandes de antes **se
guarda igual**: no se analiza todavía, pero está adentro. Si ampliás el plan, esa
historia entra al análisis sola, sin volver a mandar un archivo.

Es una diferencia que importa dos veces. Para el usuario, porque nadie le pide
que vuelva a subir un año de facturas justo después de pagar. Y para Chasqui,
porque un sistema que dice conocer el negocio no puede borrarle el pasado por su
plan de precios: sin historia no hay "esto mejoró", ni "hace tres meses lo
comprabas más barato", ni comparación contra el mismo mes del año anterior.

Cuando quedan registros fuera de la ventana, el bot lo dice al terminar la carga:
cuántos son, y que están guardados esperando. `/plan` lo muestra en cualquier
momento.

### Cupo de análisis

Cada análisis consume recursos del modelo de lenguaje. Cada negocio tiene un
**cupo mensual**. Si lo supera:

- Chasqui **no ejecuta** el análisis (no gasta de más).
- El usuario recibe: *"Tu negocio superó el cupo mensual de análisis. Se renueva
  el [fecha]."*

El control se hace **antes** de gastar, no después.

---

## 16. Qué pasa cuando algo falla

El sistema está hecho para que el usuario **nunca vea un error técnico**:

| Situación | Lo que ve el dueño |
|---|---|
| Un archivo llegó dañado | "Procesé 3 de 4 archivos, revisa factura_2.xml". El resto sigue. |
| El archivo no se pudo leer bien | Ninguna fila se carga a medias: el archivo se marca con el motivo (qué columna falló) y se puede volver a subir corregido. |
| El análisis se cayó a mitad | En pocos minutos: "Algo salió mal generando tu informe. Ya quedé avisado." No queda esperando para siempre. |
| Dejó el análisis a medias | A las 24 h: un recordatorio único para retomarlo. |
| El modelo intentó inventar una cifra | Recibe el informe con datos ciertos, sin la narración dudosa. |
| Tocó dos veces el mismo botón | "Esa ya no está pendiente" en vez de cerrar dos veces. |

Detrás, cada falla queda registrada y el administrador recibe el detalle técnico
por su chat. El usuario solo ve lenguaje humano.

---

## 17. Privacidad

- La identidad del usuario es su **cuenta de Telegram**; no hay contraseñas. El
  portal se abre con un enlace de un solo uso que vence a los 15 minutos.
- Antes de procesar cualquier dato, el usuario **autoriza explícitamente** el
  tratamiento, y queda registrada la fecha.
- Los datos del negocio (facturas, ventas, informes) son de ese negocio; el
  sistema los guarda para poder darle continuidad al servicio y sus análisis.
- Al modelo de lenguaje solo le llegan **cifras ya calculadas y nombres de
  columnas**, nunca los archivos completos: al aprender el formato de un POS, el
  modelo ve los nombres de las columnas y cinco filas de muestra, y las cifras
  las carga el sistema.

---

## 18. WhatsApp

El mismo Chasqui atiende por WhatsApp: la conversación, los botones y los
informes son los mismos, porque el cerebro es uno solo. Está implementado y
**esperando credenciales de Meta** para activarse. Los detalles del alta están en
`docs/WHATSAPP.md`.

---

## 19. Por qué está construido así (para no-técnicos)

Todo el "cerebro" de Chasqui —los textos, las reglas, los umbrales, la forma de
redactar los informes, qué servicios existen, qué preguntas sabe responder— vive
en una **base de datos**, no en el programa. Consecuencia práctica para el
negocio:

- **Lanzar un servicio nuevo, agregar una pregunta que sepa responder o cambiar
  el tono de los informes de los 40 clientes es un cambio de configuración, no
  una reprogramación.** Se hace en minutos y sin riesgo de romper lo que ya
  funciona.
- El sistema aguanta decenas de servicios sin volverse un enredo.
- Si algo se pierde, la base de datos es la copia de seguridad de todo el
  negocio.
