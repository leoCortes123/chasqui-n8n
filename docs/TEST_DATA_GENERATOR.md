# Generador de datasets de prueba

Cómo ejercitar los casos de uso de Chasqui con muchos negocios y escenarios
controlados, sin depender de datos privados de clientes.

El dataset se adapta a Chasqui, nunca al revés: todo entra por las rutas de
ingesta que existen, y lo que no se puede representar por esas rutas está
declarado como limitación al final y no se fuerza.

---

## 1. Las cuatro piezas

| Pieza | Qué hace |
|---|---|
| `bin/gen_datos_prueba.py` | Lee UCI y **escribe archivos**: CSV de ventas y facturas UBL 2.1 de compra. No toca la base ni sabe de ella. |
| `bin/cargar_datos_prueba.py` | Recorre mes a mes y mete esos archivos a Chasqui **por la ruta real de ingesta**. |
| `bin/validar_datos_prueba.py` | Valida el dataset contra sí mismo y calcula el **oráculo independiente**. |
| `db/pruebas/escenarios_generados.sql` | Comprueba que Chasqui vea en los datos cargados **exactamente** lo que el manifest declara. |

`bin/pruebas.sh` corre los cuatro bancos de `db/pruebas/` y resume cada uno. Tres
dan su propio veredicto; `router_casos` no lleva ninguno y tampoco un golden a
propósito: tres de sus casos —`/salud`, `/matching`, `/pendientes`— son comandos
de administración que reportan la base **entera**, así que su salida cambia con
cada dataset cargado y ninguna foto guardada seguiría siendo válida. Se corre
para ver que no reviente y se lee con `-v`.

Más `bin/datos_prueba_comun.py`: lector de `.xlsx` sin dependencias, `psql` por
docker, NIT con dígito de verificación y normalización de salida.

---

## 2. Ejecución

```bash
# 0. una sola vez: bajar el dataset y dejarlo donde el generador lo busca
#    https://archive.ics.uci.edu/dataset/502/online+retail+ii
mkdir -p docs/ejemplos/fuente
mv ~/Descargas/online_retail_II.xlsx docs/ejemplos/fuente/

# 1. generar
python3 bin/gen_datos_prueba.py \
  --input docs/ejemplos/fuente/online_retail_II.xlsx \
  --output docs/ejemplos/generados \
  --profile medium --seed 20260815

# 2. validar y calcular el oráculo  (falla con código 1 si algo no cuadra)
python3 bin/validar_datos_prueba.py

# 3. cargar por la ruta real de ingesta
python3 bin/cargar_datos_prueba.py --reset

# 4. verificar contra Chasqui
bash bin/pruebas.sh escenarios_generados

# ...o los cuatro bancos de una
bash bin/pruebas.sh
```

La primera lectura del `.xlsx` tarda ~40 s y deja un cache
`online_retail_II.limpio.csv` al lado del original; las siguientes tardan
segundos. Ni el original ni el cache se versionan.

Opciones útiles:

```bash
python3 bin/cargar_datos_prueba.py --escenario saludable --escenario margen_bajo
python3 bin/cargar_datos_prueba.py --cierre      # + alertas e informes periódicos
python3 bin/validar_datos_prueba.py --sin-base   # sin consultar `parametros`
```

`--reset` borra **solo** los negocios cuyo nombre empieza por `PRUEBA GEN `.
El resto de la base no se toca.

---

## 3. La estructura real de entrada de Chasqui

Lo que sigue es lo que se verificó contra el código antes de escribir nada, y
es lo que explica la forma del generador.

**Ventas — CSV tabular.** El formato semilla `pos_csv_generico` tiene la huella
de cabeceras `fecha,producto,categoria,cantidad,precio_unitario,total`. Con esa
cabecera exacta la carga cuesta cero tokens; cualquier otra dispara inferencia
de mapeo por LLM dentro de `wf_ingesta`. El generador emite siempre esa
cabecera.

```
ingesta_registrar_documento → ingesta_identificar_tabular
                            → ingesta_cargar_tabular → match_resolver_documento
```

**Compras — solo XML DIAN (UBL 2.1).** No hay clave canónica `proveedor` en el
mapeo tabular, y `movimientos.tercero_id` solo lo puebla `cartera_facturar_dian`.
Un CSV de compras no genera ni un proveedor, y sin proveedor las reglas
`proveedor`, `proveedor_sube` y `dependencia` no pueden disparar. Por eso el
generador emite facturas UBL sintéticas.

```
ingesta_registrar_documento → ingesta_procesar_documento
                            → ingesta_parsear_dian → cartera_facturar_dian
                            → match_resolver_documento
```

**Conteos de inventario — por el portal**, `portal_conteo_guardar()`.
`ingesta_cargar_inventario` existe pero está desconectada de `wf_ingesta`.

**Cartera — dos rutas.** XML DIAN para cuentas por pagar (sale sola de las
facturas de compra) y `portal_factura_guardar()` + `pago_registrar()` para
cuentas por cobrar.

Las tres funciones `portal_*` leen el negocio de
`current_setting('request.jwt.claims')`, así que el cargador abre la sesión con
`set_config('request.jwt.claims', '{"negocio_id": N}', true)` antes de llamarlas.

**Ciclo analítico — invocable por SQL, sin LLM:** `snapshot_tomar`,
`recomendaciones_registrar`, `recomendaciones_medir`, `recomendacion_accion`,
`alertas_evaluar`, `informes_periodicos_disparar`.

### Las dos cosas que ordenan todo el diseño

**El negocio nace con `plan='pro'` y NIT válido.** En plan `free` —el default—
`mov_visibles` recorta la historia a tres meses y `vs_ano_anterior` es
imposible. Y `cartera_facturar_dian` decide venta contra compra comparando
`negocios.nit` con el emisor del XML: sin NIT todo cae en `compra`, no hay
cuentas por cobrar y `cartera` no dispara nunca.

**Se carga por tramos, con snapshot entre tramos.** `snapshot_tomar` fotografía
siempre la historia visible completa, no un período: para tener una serie
comparable hay que intercalar `cargar mes → snapshot → cargar mes → snapshot`.
Sin eso, `margen_cae` y la medición de resultados son inalcanzables.

---

## 4. Estructura de salida

```
docs/ejemplos/
  fuente/                       ← UCI original + cache (gitignored)
  generados/                    ← gitignored salvo manifests/
    <escenario>/
      ventas_YYYYMM.csv                     cabecera de pos_csv_generico
      compra_YYYYMM_proveedor_demo_NNN.xml  UBL 2.1 (Invoice)
      compra_..._adjunta.xml                AttachedDocument con CDATA
      ventas_YYYYMM_rechazable.csv          solo en `datos_incompletos`
    manifests/
      scenarios.json    lo que el dataset DECLARA + el plan de carga
      oracle.json       lo que el dataset PRODUCE, calculado aparte
```

`scenarios.json` lleva, por escenario, los campos del plan (negocio, seed,
período, productos, proveedores, eventos, reglas esperadas, reglas prohibidas,
estado esperado) más una sección `carga` que es el guion mes a mes que consume
`cargar_datos_prueba.py`: qué archivos, qué conteos, qué facturas, qué pagos y
qué acciones del dueño van en cada mes.

---

## 5. Transformación UCI → Chasqui

Fuente: **UCI Online Retail II**, 1.067.371 transacciones de dos años
(2009-12 a 2011-12), columnas `InvoiceNo, StockCode, Description, Quantity,
InvoiceDate, UnitPrice, CustomerID, Country`.

### Lo que se descarta, y por qué

| Filas | Decisión |
|---|---|
| `Quantity < 0` y `InvoiceNo` con prefijo `C` | Devoluciones y cancelaciones: 22.951 filas. Chasqui no tiene un tipo de movimiento para eso — `'ajuste'` existe en el ENUM pero no lo produce ninguna ruta de ingesta ni lo consume ninguna vista. Se descartan. |
| `Description` vacía o precio/cantidad cero | No son ventas. Se descartan del flujo principal. |
| Productos con menos de 60 líneas, nombre no imprimible o precio fuera de 0,30–60 GBP | No dan material para una serie mensual ni se leen como un catálogo de POS. |

### Lo que se conserva

Frecuencia de ventas, mezcla de productos, cantidades, dispersión de precios,
forma estacional y concentración tipo Pareto. Los datos base conservan la
irregularidad real: dentro de cada mes, cada fila es una línea de factura de UCI
con su día y su cantidad.

### Las tres intervenciones, declaradas

1. **Escala a pesos.** `UnitPrice × 5.000`, redondeado a $50. No es una
   cotización: es un factor de escala redondo y documentado. Los umbrales de
   priorización de Chasqui trabajan sobre `base_mes` en pesos, y sin escalar la
   relevancia de cada recomendación no se parecería a la de un negocio
   colombiano.

2. **Re-anclaje del calendario.** El último mes sintético es el último mes
   **completo** anterior a `current_date`; los anteriores van hacia atrás mes a
   mes. Cada mes sintético toma sus filas del mes de UCI con **el mismo mes del
   año**, para que la estacionalidad caiga donde corresponde y para que
   `vs_ano_anterior` compare dos meses con la misma estacionalidad. Las fechas
   originales (2009–2011) no sirven: la cartera mide mora contra el calendario
   real y las alertas también.

3. **Escala mensual en pesos.** El total de cada mes se lleva a un objetivo
   `media × estacionalidad × tendencia × ruido`, reescalando las cantidades. La
   estacionalidad sale de los propios productos del negocio promediada sobre los
   dos años de UCI —así el índice de cada mes es el mismo en los dos años—, la
   tendencia la declara el escenario, y el ruido de un mes es **el mismo** que
   el del mismo mes del año anterior. Sin esto, dos meses con las mismas
   unidades pueden diferir un 30% en plata solo porque se vendió otra mezcla de
   productos, y esa diferencia se leería como una caída interanual que nadie
   diseñó.

Cada negocio recibe una tajada **disjunta** del catálogo de UCI. La prueba de
aislamiento no depende de que nadie se equivoque después: dos negocios generados
no pueden compartir un nombre de producto porque nunca lo tuvieron.

---

## 6. Datos sintéticos agregados

Nada de esto está en UCI.

**Proveedores.** `PROVEEDOR DEMO 001`, `002`, … con NIT sintético y dígito de
verificación válido. La numeración es global: dos negocios nunca comparten
proveedor. Tres por negocio (cuatro donde el escenario lo pide), y los productos
se reparten por carga —el proveedor con menos gasto asignado se lleva el
siguiente— para que ninguna participación llegue al 50% sin quererlo.

**Costos.** El costo de cada producto sale del precio de venta y del margen que
el escenario declara. Las compras se derivan de las ventas, nunca al azar: cada
mes se compra lo que ese mes se vendió, y en el primer mes con ventas se compra
además el colchón que deja la **cobertura objetivo** —25 días en el caso normal,
3 donde tiene que dispararse `agota`, 150 donde tiene que dispararse `quieto`—.
Así nunca se vende más de lo que entró y el stock final es exactamente el que la
regla necesita ver.

**Inventario.** Los tres orígenes de stock aparecen en cada negocio: un producto
recién contado (`conteo`), uno contado a mitad de período con movimientos
después (`calculado`) y el resto sin conteo (`estimado`). Los conteos se
calculan para que el balance final siga siendo el de la cobertura objetivo: un
conteo puesto a ojo mueve `dias_cobertura` y dispara `quieto` o `agota` donde el
escenario los prohíbe. Y caen sobre productos **sin marcar**, porque el producto
marcado ya tiene su papel.

**Cartera.** Cuentas por cobrar por `portal_factura_guardar()`, con cuatro
situaciones repartidas entre los escenarios: sin cartera, al día, vencida con
impacto relevante, y vencida y pagada después. El saldo vencido se dimensiona
contra lo que el negocio mueve en un mes, para que la prioridad quede en `alta`:
es lo que hace posible probar `alertas_evaluar()`, que solo mira las altas.

**Facturas UBL.** `Invoice` con `AccountingSupplierParty` /
`AccountingCustomerParty` (`RegistrationName` + `CompanyID`), `InvoiceLine` con
descripción, EAN-13 sintético en `StandardItemIdentification`, cantidad con
`@unitCode`, `LineExtensionAmount` y `Price/PriceAmount`, más `TaxTotal` al 19% y
`LegalMonetaryTotal/PayableAmount` que cuadran:
`|Σ líneas + impuesto − PayableAmount| < 1`. El primer documento de cada negocio
va envuelto en un `AttachedDocument` con el `Invoice` en CDATA, que es lo que
llega por correo en la vida real.

---

## 7. Los doce escenarios

Perfil `medium`. La columna de la derecha es lo que el banco SQL comprueba que
**no** aparezca.

| Escenario | Dispara | No dispara |
|---|---|---|
| `saludable` | — | las once |
| `margen_bajo` | `margen` | `costo`, `agota` |
| `costos_crecientes` | `costo`, `proveedor_sube`, `margen_cae`, `margen` | `quieto` |
| `inventario_excesivo` | `quieto` | `agota` |
| `productos_agotandose` | `agota` | `quieto` |
| `proveedor_caro` | `proveedor`, `cartera` | `dependencia` |
| `ventas_decrecientes` | `sin_ventas`, `vs_ano_anterior` | `agota` |
| `ventas_crecientes` | — | `sin_ventas`, `vs_ano_anterior`, `margen`, `costo` |
| `estacional` | — | `vs_ano_anterior`, `sin_ventas` |
| `datos_incompletos` | `cartera`, `agota` | — |
| `multiples_proveedores` | `dependencia` | `proveedor`, `cartera` |
| `accion_exitosa` | — (cierra con `resultado='positivo'`) | `margen` |

`estacional` es la prueba de **falso positivo**: una caída estacional legítima
—julio vendiendo un tercio de lo que vendió diciembre— no debe leerse como
deterioro, porque el julio del año pasado vendió lo mismo.

### Cómo se construye cada disparo

| Regla | Umbral efectivo | Cómo se produce |
|---|---|---|
| `costo` | `deriva_pct >= 10` | rampa de +40% en el costo de punta a punta |
| `proveedor` | `pagado > mejor × 1,05` | el mismo producto al proveedor caro todo el período y al barato (−28%) el último mes |
| `margen` | `margen_pct < 15` | precio de venta puesto a costo/(1−0,10) |
| `agota` | `dias_cobertura < 7` | cobertura objetivo de 3 días |
| `quieto` | `dias_cobertura > 60` y balance > 0 | cobertura objetivo de 150 días |
| `dependencia` | `>= 50%` del gasto | un proveedor se lleva el 60% de los productos |
| `sin_ventas` | 45 días sin vender, ≥3 ventas, span ≥14 días | el producto deja de venderse los últimos 3 meses |
| `proveedor_sube` | ≥3 subidas en 365 días | la misma rampa de costo, una subida por mes |
| `margen_cae` | dos caídas seguidas, ≥3 pp | la rampa de costo con el precio quieto: ~2 pp por mes entre snapshots |
| `vs_ano_anterior` | caída ≥15% del último mes completo | tendencia declinante hasta 0,55 |
| `cartera` | mora >15 días, saldo vencido > 0 | factura por el 80% de un mes de ventas, vencida hace 40 días |

El tamaño del escalón mensual del costo no es cosmético: `margen_cae` exige tres
mediciones seguidas cayendo y al menos 3 puntos porcentuales entre la primera y
la última. Con una rampa suave el margen baja medio punto por mes y la regla no
puede verlo aunque el costo se esté disparando.

---

## 8. El oráculo

`docs/ejemplos/generados/manifests/oracle.json` se calcula **en Python desde los
archivos generados**, implementando cada umbral desde su definición y no
traduciendo el SQL de Chasqui. Si el oráculo repitiera la misma consulta, un
mismo error pasaría las dos pruebas.

```
costo:            (costo_final − costo_inicial) / costo_inicial >= 0,10
proveedor:        precio_pagado > min(precio_por_proveedor) × 1,05
margen:           (precio − costo) / precio × 100 < 15
agota:            balance / (unidades_vendidas / dias_ventana) < 7
quieto:           balance / (unidades_vendidas / dias_ventana) > 60 y balance > 0
dependencia:      gasto_proveedor / gasto_total >= 0,50
sin_ventas:       dias_desde_ultima_venta > 45, ventas >= 3, span >= 14
proveedor_sube:   count(precio > previo × 1,01) >= 3 en 365 días
margen_cae:       margen[t] < margen[t−1] < margen[t−2], caída >= 3 pp
vs_ano_anterior:  (ventas_mes_ref − ventas_mismo_mes_año_anterior) / anterior <= −0,15
cartera:          sum(saldo where vencimiento < hoy − 15d) > 0
```

`precio` y `costo` son los de la **punta** de la serie —la última venta y la
última compra—, no promedios: es lo que miran `v_precio_actual_producto` y
`v_costo_actual_producto`.

El oráculo también declara, para el conteo que contradice la estimación, qué
regla corresponde **antes** y **después** del conteo. La comparación final es
`ORÁCULO(archivos)` contra `recomendaciones_negocio(negocio, true)`.

---

## 9. Perfiles, seed y reproducibilidad

```
--profile small     3 negocios,  6 meses,  ~14.000 movimientos
--profile medium   12 negocios, 15 meses,  ~53.000 movimientos   (referencia)
--profile large    20 negocios, 24 meses, ~180.000 movimientos
```

`medium` es el perfil de referencia: 15 meses es el mínimo cómodo para
`vs_ano_anterior`, que necesita trece. `small` carga tres escenarios y **no
puede** ejercitar las reglas que necesitan más de un año — el banco SQL marca
los escenarios ausentes como `WARN` y no como falla.

El tamaño lo fija `lineas_mes`, el tope de líneas de venta por negocio y por
mes. Es lo que decide el tiempo de carga, que es lo que de verdad duele: cada
archivo viaja a `ingesta_cargar_tabular` como un literal JSON embebido en el SQL,
así que se trocea un archivo por negocio por mes y nunca un lote de cientos de
miles de filas.

`--seed` fija catálogos, calendario, cantidades, precios, proveedores y
escenarios. Como todos los IDs de Chasqui son `IDENTITY`, la reproducibilidad se
verifica sobre los **archivos**, que no tienen ids, y sobre salida normalizada
para lo que sí los tiene (`norm()` en `bin/datos_prueba_comun.py` enmascara ids
de secuencia, fechas ISO y claves `producto:N`, con la técnica de `_norm()` en
`db/pruebas/router_casos.sql`).

`validar_datos_prueba.py` resume todo eso en un número: la **huella
normalizada**, sha256 sobre todos los archivos generados pasados por `norm()`.

```bash
python3 bin/gen_datos_prueba.py --seed 20260815 --output /tmp/a
python3 bin/gen_datos_prueba.py --seed 20260815 --output /tmp/b
diff -r /tmp/a /tmp/b        # solo difiere manifests/scenarios.json:generado_en

python3 bin/validar_datos_prueba.py --manifest /tmp/a/manifests/scenarios.json
python3 bin/validar_datos_prueba.py --manifest /tmp/b/manifests/scenarios.json
#   [PASS] global/huella normalizada del dataset   5ddf867e443ce0c0144f184be6aa82fd
```

Comprobado: misma seed → archivos byte a byte idénticos, manifest idéntico salvo
la marca de tiempo y la misma huella `5ddf867e…`, incluso con distinto
`PYTHONHASHSEED`. Seed distinta → otro dataset (`--seed 777` da la huella
`3a033457…`), igual de válido: pasa las mismas 149 comprobaciones.

---

## 10. Invariantes

Los que comprueba `bin/validar_datos_prueba.py` antes de tocar la base:

1. Nombre, NIT y `telegram_chat_id` únicos en todo el dataset.
2. Cantidades y precios positivos, y `total = cantidad × precio_unitario`.
3. Las compras sostienen las ventas: ningún producto se vende más de lo que
   entró.
4. `|Σ líneas + impuesto − PayableAmount| < 1` en cada XML.
5. Todas las fechas dentro del período declarado.
6. Ningún archivo de un negocio menciona productos ni proveedores de otro.
7. El oráculo ve las reglas esperadas y ninguna de las prohibidas.
8. ≥13 meses en los negocios que declaran `vs_ano_anterior`.
9. Ningún documento supera el 20% de filas sin fecha, salvo el diseñado para
   probar el rechazo — que sí lo supera, y eso también se comprueba.
10. Todo negocio nace con `plan='pro'` y NIT con dígito de verificación válido,
    y los NIT de proveedor también.
11. Los umbrales con los que se generó siguen siendo los de la tabla
    `parametros`. Si alguien los mueve, la validación falla a la vista.

Y los que comprueba `db/pruebas/escenarios_generados.sql` contra la base, además
de las reglas de cada escenario: el ciclo recomendación → acción → datos nuevos
→ resultado `positivo`; dos snapshots no parciales con fechas distintas; los
tres orígenes de stock; el conteo que contradice la estimación cambiando la
recomendación de `quieto` a `agota`; las filas sin producto conservadas con
alias `pendiente` y reportadas por `alias_pendientes()` con la plata que
representan; `match_confirmar_alias` resolviendo hacia atrás; alertas con
cooldown; el informe periódico que no se dispara sin un análisis previo; y
**aislamiento**: ningún movimiento, alias, conteo, factura, recomendación ni
snapshot de un negocio referencia objetos de otro.

---

## 11. La corrida real de `wf_ejecutar`

Todo lo anterior corre por SQL y no gasta un token. Una vez, sobre un negocio
generado, conviene correr la cadena completa: es lo único que comprueba que el
informe se arme, que el modelo responda y que `validar_cifras` acepte lo que
escribió.

`wf_ejecutar` es un sub-workflow que recibe `{ejecucion_id}`: no se dispara
solo. Se llega a él por el router, con el webhook de Telegram:

```bash
set -a; . ./.env; set +a
CHAT=888001                     # el chat del primer negocio generado

post() {
  curl -s -X POST "http://127.0.0.1:5678/webhook/$TELEGRAM_WEBHOOK_PATH" \
    -H "Content-Type: application/json" \
    -H "X-Telegram-Bot-Api-Secret-Token: $TELEGRAM_WEBHOOK_SECRET" \
    -d "{\"update_id\":$RANDOM,\"message\":{\"message_id\":$RANDOM,
         \"from\":{\"id\":$CHAT},\"chat\":{\"id\":$CHAT,\"type\":\"private\"},
         \"date\":$(date +%s),\"text\":\"$1\"}}"
}

post /nueva
post svc:ventas_compras
# el simulador cargó los archivos sin conversación: se ata uno a esta sesión
#   UPDATE documentos SET sesion_id = <sesion>
#    WHERE id = (SELECT max(id) FROM documentos
#                 WHERE negocio_id = <negocio> AND estado = 'parseado');
post /analizar
```

Para que el router reconozca al usuario hace falta su fila en `identidades`
—el router busca por ahí y no por `usuarios.telegram_user_id`—; el cargador la
crea junto con el negocio.

Resultado de la corrida sobre `PRUEBA GEN saludable`: ejecución completada en
59 s, 1.758 tokens de prompt y 5.144 de salida, informe de 1.157 caracteres y
`validar_cifras` en `{"ok": true, "inventadas": []}`. El informe reporta un
margen promedio de 32,02% —exactamente el que el generador apunta para un
negocio sano— e índice de salud 82, sin ninguna recomendación de deterioro.

`wf_enviar` sí falla después, con `Bad request` de Telegram: el chat 888001 no
existe. Es esperable y no afecta al análisis, que ya quedó guardado en
`ejecuciones.texto`.

---

## 12. Los ejemplos curados que ya estaban

Estas carpetas son anteriores al generador, no se tocan y siguen siendo el banco
manual de la ingesta.

### `docs/ejemplos/dian_oficiales/` — 13 facturas del set oficial DIAN

Único corpus **no sintético** del repositorio, y la referencia estructural del
emisor UBL. Cubre factura genérica, de servicios, de combustible, de transporte
de carga, a consumidor final, con excluidos y exentos, de emisor autorretenedor,
de exportación, en moneda extranjera, de mandatos, con pago anticipado, más una
nota crédito y una nota débito.

Sirven para comprobar que `ingesta_parsear_dian` no se rompe con las variantes
que la DIAN admite: `CreditNote` y `DebitNote` tienen su propia raíz y su propio
nombre de línea, y el parser los despacha por `local-name(/*)`.

### `docs/ejemplos/historial_6meses/` — el banco de la inferencia de formatos

Seis meses de un mismo negocio ficticio: 6 compras UBL y 6 ventas CSV sobre un
catálogo compartido de 26 productos colombianos, con variantes de escritura
entre la compra y la venta para ejercitar el matching por trigram.

Lo importante es que **cada mes trae un layout de POS distinto**:

| Archivo | Layout |
|---|---|
| `ventas_202602_pos_familiar.csv` | la huella conocida de `pos_csv_generico` |
| `ventas_202603_pos_alias.csv` | mayúsculas y nombres abreviados (`CANT`, `PRECIO`) |
| `ventas_202604_crm_english.csv` | cabeceras en inglés (`date`, `item`, `qty`) |
| `ventas_202605_pos_latam.csv` | separador `;` y números `2.500,00` |
| `ventas_202606_pos_decimal_punto.csv` | huella conocida, importes con `.00` |
| `ventas_202607_crm_tablet.csv` | timestamp en la fecha y otros nombres de columna |

Cinco de los seis tienen huella desconocida y disparan la inferencia de mapeo
por LLM dentro de `wf_ingesta`. Por eso se cargan **a mano, una vez**, y no
entran al dataset generado: cada huella nueva es una llamada al modelo.

> El archivo de junio se llamaba `ventas_202606_pos_semicolon.csv` y no usa
> punto y coma sino comas; el que usa `;` es el de mayo. Se renombró a
> `ventas_202606_pos_decimal_punto.csv`, que es lo que de verdad lo distingue.

### `docs/ejemplos/01..05`

Casos sueltos de la ingesta: factura simple, factura adjunta con CDATA, factura
de 4 productos con EAN, ventas en formato conocido y ventas en formato a
aprender.

---

## 13. Discrepancias con el plan, y qué se hizo

El plan de encargo (`docs/historico/PLAN_DATOS_PRUEBA.md`) describía el sistema con la
precisión posible antes de implementar. Al implementar aparecieron seis
diferencias con el código real. En todas se adaptó el generador a la
implementación, no al revés.

| # | El plan decía | El código dice | Qué se hizo |
|---|---|---|---|
| D1 | «cargar mes → `snapshot_tomar` → cargar mes → `snapshot_tomar`» | `snapshot_tomar` graba siempre con `fecha = current_date` y tiene `UNIQUE (negocio_id, fecha)`: quince meses simulados en una tarde son quince veces la misma fila | La foto la sigue tomando la función real; el simulador mueve después la fecha de la fila al mes que representa. Es el reloj de la simulación, no lógica de negocio. Sin esto `margen_cae` es inalcanzable. |
| D2 | `margen`: `margen_pct < 20` | `parametros.margen_minimo_pct = 15` | El generador apunta a 15 y `validar_datos_prueba.py` comprueba contra la base que siga siendo 15. |
| D3 | `costo`: `deriva_pct >= 8` | `parametros.deriva_costo_alerta_pct = 10` | Igual: el umbral efectivo se toma de la base y se verifica. |
| D4 | `quieto`: `dias_sin_rotar > 60` | `v_rotacion_producto.dias_cobertura > 60` y `balance > 0` — es cobertura, no días sin rotar | El oráculo implementa cobertura. Son cosas distintas: un producto puede venderse todos los días y aun así tener inventario para medio año. |
| D5 | `dependencia`: `> 50%` del gasto | `>= 50%` | El oráculo usa `>=`. |
| D6 | `match_confirmar_alias` «cambia los resultados retroactivamente» | efectivamente lo hace: actualiza los `movimientos` con `producto_id IS NULL` cuyo alias o texto normalizado coincide | Confirmado, y el banco lo comprueba contando antes y después sin tocar `movimientos` a mano. |
| D7 | (no lo mencionaba) | el router no busca al usuario por `usuarios.telegram_user_id` sino por la tabla `identidades` | El cargador crea la fila de `identidades` junto con el negocio. Sin ella, el primer mensaje desde ese chat intenta crear un usuario nuevo y choca contra el índice único de `telegram_user_id` — que es exactamente lo que pasó el primer intento de correr `wf_ejecutar`. |
| D8 | «`quieto`: `dias_sin_rotar`» y `salud_negocio` con seis notas en un array | `salud_negocio` devuelve seis CLAVES de un objeto (`ventas`, `margenes`, `inventario`, `compras`, `riesgos`, `liquidez`) más `indice`, no un array `notas` | El banco cuenta las seis claves. |

Una diferencia más, de orden: el plan describía «cargar ventas del mes → cargar
compras del mes». Cargadas en ese orden, las ventas del primer mes llegan antes
de que exista ningún producto —los productos nacen del EAN de la factura DIAN— y
quedan con `producto_id NULL` y un alias `pendiente` que ya no se arregla solo.
El cargador carga **compras primero**, que además es el orden de la vida real.

---

## 14. Limitaciones

- **La inferencia de formatos desconocidos no está en el dataset generado.**
  Requiere una llamada al LLM dentro de `wf_ingesta`, y el generador no
  introduce llamadas a LLM. Los seis layouts de `historial_6meses/` siguen
  siendo el banco de esa prueba, cargados a mano.
- **`'ajuste'` no se genera.** Existe en el ENUM `tipo_movimiento` pero ninguna
  ruta de ingesta lo produce ni ninguna vista lo consume, así que las
  devoluciones y cancelaciones de UCI se descartan en vez de representarse mal.
- **`alertas_evaluar()` no se puede probar fuera de la franja 8–20 de
  `America/Bogota`.** Fuera de horario devuelve vacío; el banco lo marca como
  `WARN` en vez de dar un falso negativo.
- **El informe periódico necesita una `ejecuciones` completada previa**, que el
  banco inserta él mismo dentro de su transacción: no hay ruta de datos que la
  produzca sin correr `wf_ejecutar`, y correrlo doce veces cuesta tokens.
- **La corrida real de `wf_ejecutar` es una, sobre un negocio generado** (§11).
  El resto del ciclo se simula por SQL. Es a propósito: lo que se prueba con
  tokens es que la cadena completa produzca informe y pase `validar_cifras`, no
  cada escenario. Y la entrega falla siempre, porque los `telegram_chat_id`
  generados (rango `888xxx`) no son chats reales.
- **El perfil `small` no alcanza para las reglas comparativas.** Seis meses no
  son trece.
- **Los nombres de producto son los de UCI, en inglés.** Se conservan tal cual
  para no inventar un catálogo colombiano que no tendría el comportamiento de
  compra que se está reutilizando. Los nombres colombianos están en
  `historial_6meses/`.

---

## 15. Atribución

Chen, D. (2019). *Online Retail II* [Dataset]. UCI Machine Learning Repository.
<https://doi.org/10.24432/C5CG6D> — licencia **CC BY 4.0**.

El dataset original no se versiona en este repositorio. La atribución viaja
también dentro de `manifests/scenarios.json`.

Los nombres de proveedor y de cliente son inequívocamente sintéticos
(`PROVEEDOR DEMO 001`, `CLIENTE DEMO …`) y los NIT están construidos para ser
válidos y no corresponder a ninguna empresa real. No hay datos que parezcan de
personas identificables: de UCI se usa el catálogo de productos y la forma
temporal, nunca `CustomerID` ni `Country`.
