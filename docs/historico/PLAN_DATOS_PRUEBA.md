# Plan de trabajo: generador reproducible de datasets de prueba

*Documento de encargo. Se le pasa entero a una sesión nueva de Claude Code, parada
en la raíz del repositorio, como único enunciado de la tarea.*

---

Trabajás sobre el repositorio Chasqui: bot de Telegram/WhatsApp para análisis de
negocios, sobre n8n + Postgres. El roadmap del producto está completo (fases A–F,
migraciones 053–069) y verificado.

Esta tarea **no** agrega funcionalidad al producto, **no** modifica la arquitectura
y **no** toca la lógica de negocio. Es infraestructura local de pruebas: poder
ejercitar los casos de uso de Chasqui con muchos negocios y escenarios controlados,
sin depender de datos privados de clientes.

El dataset se adapta a Chasqui, nunca al revés. Si algo no se puede representar por
las rutas de entrada existentes, se documenta como limitación y no se fuerza.

La fuente de comportamiento real es el dataset público **UCI Online Retail II**
(~1.067.371 transacciones, dos años; columnas `InvoiceNo, StockCode, Description,
Quantity, InvoiceDate, UnitPrice, CustomerID, Country`). Todo lo que UCI no
contiene —costos, proveedores, inventario, cartera— se sintetiza.

---

## 1. Estructura de Chasqui: lo que ya está verificado

Lo que sigue está comprobado contra el código, las migraciones y la base viva.
Tomalo como punto de partida. Verificá solo lo que vayas a tocar; no vuelvas a
investigar el esquema completo.

### Nombres de objetos

| Concepto | Objeto real |
|---|---|
| Proveedores y clientes | tabla `terceros (id, negocio_id, nit, nombre)` |
| Motor de reglas | **función** `recomendaciones_negocio(bigint, boolean)`; la tabla es `recomendaciones` |
| Índice de salud | **función** `salud_negocio(bigint)`, seis notas: ventas, margenes, inventario, compras, riesgos, liquidez |
| Informes | no hay tabla; un informe es una fila de `ejecuciones` |
| Snapshots | tabla `snapshots_negocio`, `UNIQUE (negocio_id, fecha)` |
| Alertas | tabla `alertas_enviadas` + función `alertas_evaluar()` |
| Inventario declarado | tabla `conteos_inventario` |
| Cartera | tablas `facturas` y `pagos` |
| Matching | tablas `productos` y `alias` |

Todos los IDs son `bigint GENERATED ALWAYS AS IDENTITY`; los catálogos usan PK de
texto (`servicios.codigo`, `formatos_documento.codigo`, …). **No existen IDs
deterministas.** La identidad estable de un negocio generado es su `nombre`.

`tipo_movimiento` es un ENUM `('compra','venta','ajuste')`. `'ajuste'` no lo produce
ningún camino de ingesta ni lo consume ninguna vista: no lo uses.

Vistas de cálculo, todas leyendo `mov_visibles`: `v_costo_actual_producto`,
`v_precio_actual_producto`, `v_margen_producto`, `v_deriva_costo`,
`v_balance_unidades`, `v_rotacion_producto`, `v_pareto_utilidad`,
`v_proveedor_mas_barato`, `v_perfil_negocio`, `v_cartera_edades`,
`v_cartera_tercero`.

### Las once reglas de recomendación

Estos son los valores reales de `recomendaciones.regla` y de `alertas_enviadas.regla`:

| regla | clave_objeto | umbral | datos que exige |
|---|---|---|---|
| `costo` | `producto:<id>` | `deriva_pct >= 8` | ≥2 compras del producto |
| `proveedor` | `producto:<id>` | `precio_pagado > precio_mejor * 1.05` | el mismo producto comprado a ≥2 proveedores |
| `margen` | `producto:<id>` | `margen_pct < 20` | compra **y** venta del producto |
| `agota` | `producto:<id>` | `dias_cobertura < 7` | ventas + balance, `unidades_por_dia > 0` |
| `quieto` | `producto:<id>` | `dias_sin_rotar > 60` y `balance > 0` | ventas + balance positivo |
| `dependencia` | `proveedor:<nombre>` | `> 50%` del gasto | compras con proveedor; prioridad forzada a `media` |
| `sin_ventas` | `producto:<id>` | 45 días sin vender, ≥3 ventas históricas, span ≥14 días | historia de ventas |
| `proveedor_sube` | `producto:<id>` | ≥3 subidas (`precio > previo*1.01`) en 365 días | compras fechadas del último año |
| `margen_cae` | `producto:<id>` | dos caídas seguidas de ≥3 pp | **2 snapshots con `metricas->'parcial' = false`** |
| `vs_ano_anterior` | `'negocio'` | caída ≥15% del último mes completo contra el mismo mes del año anterior | ~13 meses de `mov_visibles` |
| `cartera` | `tercero:<id>` | mora >15 días, `saldo_vencido > 0` | `facturas` tipo `venta` con saldo y vencimiento pasado |

Ciclo de vida de una recomendación: `nueva → vigente → resuelta | ignorada |
caducada`. El cierre lleva `cerrada_por IN ('dato','accion_usuario','sin_datos')`;
la medición de resultado usa `resultado IN ('positivo','neutro','negativo')`.

Priorización: `pct = impacto_mes * 100 / base_mes`, con vara según `impacto_tipo`
(`mensual` 2/0.5, `unico` 10/3, `capital` 50/20). Topes: 2 recomendaciones por
regla, 8 en total en el informe.

El "hoy" de las reglas comparativas es `max(fecha)` de los movimientos, **no**
`current_date` — salvo `cartera`, que sí usa el calendario real.

### Rutas de entrada de datos

**Ventas — CSV tabular.** El formato semilla `pos_csv_generico` tiene la huella de
cabeceras `fecha,producto,categoria,cantidad,precio_unitario,total`. Con esa
cabecera la carga cuesta cero tokens. Cualquier otra cabecera dispara inferencia de
mapeo por LLM dentro de wf_ingesta.

Cadena: `ingesta_registrar_documento` → `ingesta_identificar_tabular` →
`ingesta_cargar_tabular` → `match_resolver_documento`.

Claves canónicas aceptadas en un mapeo tabular: `fecha, producto, categoria,
cantidad, valor_unitario, valor_total, codigo, unidad, impuesto`. Obligatorias:
`fecha` más al menos una de `valor_total` / `valor_unitario`.

**Compras — solo XML DIAN (UBL 2.1).** No hay clave canónica `proveedor` en el
mapeo tabular, y `movimientos.tercero_id` solo lo puebla `cartera_facturar_dian`.
Un CSV de compras no genera ni un proveedor, y sin proveedor las reglas
`proveedor`, `proveedor_sube` y `dependencia` no pueden disparar. **El generador
debe emitir facturas UBL 2.1 sintéticas.**

Cadena: `ingesta_registrar_documento` → `ingesta_procesar_documento` →
`ingesta_parsear_dian` → `cartera_facturar_dian` → `match_resolver_documento`.

**Conteos de inventario — por el portal.** `ingesta_cargar_inventario` existe pero
está desconectada de wf_ingesta (el nodo `CargarTabular` llama a
`ingesta_cargar_tabular` hardcodeado, y el formato `inventario_csv` tiene `huella`
NULL). La ruta real es `portal_conteo_guardar()`.

**Cartera — dos rutas.** XML DIAN para cuentas por pagar, y
`portal_factura_guardar()` (fuerza `tipo='venta'`) + `pago_registrar()` para
cuentas por cobrar. La cartera es completamente generable sin simular nada raro.

**Snapshots y ciclo analítico — invocables por SQL, sin LLM:**
`snapshot_tomar(negocio_id, origen, ejecucion_id)`,
`recomendaciones_registrar(negocio_id, ejecucion_id)`,
`recomendaciones_medir(negocio_id)`,
`recomendacion_accion(reco_id, negocio_id, accion, usuario_id)` con acciones
`'hice' | 'no_aplica' | 'precio'`, `alertas_evaluar()`,
`informes_periodicos_disparar()`.

### Cinco condiciones que ordenan todo el diseño

**C1 — Cargar por tramos, con snapshot entre tramos.** `snapshot_tomar` fotografía
**siempre la historia visible completa** (`min(fecha)..max(fecha)` de
`mov_visibles`), no un período. Para tener una serie de snapshots comparables hay
que intercalar: cargar mes → `snapshot_tomar` → cargar mes → `snapshot_tomar`. Sin
esto, `margen_cae` y toda la medición de resultados son inalcanzables.

**C2 — Todo negocio generado nace con `plan='pro'` y `nit` válido.** `mov_visibles`
filtra por `plan_desde()`; en plan `free` (el default) la ventana de análisis son 3
meses y `vs_ano_anterior` es imposible. Y `cartera_facturar_dian` decide venta vs
compra comparando `negocios.nit` contra el emisor del XML: sin NIT, todo cae en
`compra`, no hay cuentas por cobrar y la regla `cartera` no dispara nunca. El NIT
debe pasar `nit_dv()`.

**C3 — El calendario se re-ancla a `current_date`.** Las fechas originales de UCI
(2009–2011) no sirven para cartera (mora contra el calendario real) ni para alertas.
Re-anclá conservando espaciamiento relativo, estacionalidad y concentración.
`db/pruebas/reglas_comparativas.sql` ya usa esta técnica con `generate_series` sobre
`date_trunc('month', current_date)`: seguila.

**C4 — Compuerta de calidad al cargar tabulares.** Si más del 20% de las filas de un
documento queda sin fecha o sin valor legible (`max_pct_nulos`), el documento entero
va a `error` y **no entra ni una fila**. Los escenarios de datos sucios deben quedar
por debajo de ese umbral, salvo uno diseñado explícitamente para probar el rechazo.

**C5 — Trocear por documento.** Las filas viajan a `ingesta_cargar_tabular` como un
literal JSON embebido en el SQL. Un archivo por negocio por mes; nunca un lote de
cientos de miles de filas.

### Compuertas de proactividad

`alertas_evaluar()`: solo prioridad `alta`, máximo 1 alerta por corrida, cooldown de
14 días (`alerta_cooldown_dias`), franja horaria 8–20 en `America/Bogota`, y exige un
usuario con `autorizacion_datos = true` + `telegram_chat_id`, más datos nuevos
posteriores al último análisis. Fuera de horario retorna vacío: una prueba corrida de
noche da falso negativo.

`v_negocios_informe_periodico`: exige que **ya exista** una ejecución `completada` de
un servicio con `entrada='archivos'`, más 30 días transcurridos y ≥10 movimientos
nuevos. El primer informe siempre lo pide el dueño; el cron nunca lo dispara.

### Los tres orígenes del stock

`v_balance_unidades.origen_stock`: `conteo` (hay conteo y no hubo movimientos
después), `calculado` (último conteo + comprado − vendido desde esa fecha),
`estimado` (sin conteo: comprado − vendido). No modifiques esta lógica.

---

## 2. Lo que ya existe en el repo

Reutilizalo; no lo recrees.

- **`db/pruebas/aceptacion.sql`** — 23 comprobaciones del roadmap con
  `_chk(prueba, esperado, obtenido)`, en una transacción con `ROLLBACK`, salida
  `pasaron/fallaron/total`. Es el formato de reporte del proyecto.
- **`db/pruebas/reglas_comparativas.sql`** — genera 15 meses de historia sintética
  con `generate_series` anclado a `current_date`, con productos cuyo nombre declara
  la regla esperada (`PROD-A SE PARO`, `PROD-C MARGEN CAE`), y verifica que cada
  regla dispare la suya y ninguna otra. Es el precedente directo del oráculo.
- **`db/pruebas/router_casos.sql`** — su función `_norm()` enmascara ids de
  secuencia, tokens y fechas ISO. Es lo que hace comparables dos corridas.
- **`db/limpiar_datos.sql`** — reset de datos de negocio conservando configuración;
  TRUNCATE explícito de 16 tablas sin CASCADE a propósito.
- **`bin/gen_ventas_demo.py`** — ya implementa la carga por la ruta real de ingesta,
  con `--seed`, sin dependencias de Python, leyendo `.env` a mano y llamando a `psql`
  por `docker compose exec`. Su principio, explícito en el docstring: nada de INSERTs
  a mano, para que un cambio de la ingesta rompa a la vista y no en silencio.
  Está en `.gitignore`.
- **`docs/ejemplos/dian_oficiales/`** — 13 facturas del set oficial DIAN (genérica,
  servicios, combustible, transporte, consumidor final, excluidos/exentos,
  autorretenedor, exportación, moneda extranjera, mandatos, pago anticipado, nota
  crédito, nota débito). Único corpus no sintético del repo; plantilla estructural
  para el emisor UBL.
- **`docs/ejemplos/historial_6meses/`** — 6 compras UBL + 6 ventas CSV, **un layout
  de POS distinto cada mes** (mayúsculas, inglés, `;` con `2.500,00`, timestamp,
  decimal con punto), sobre un catálogo compartido de 26 productos colombianos con
  variantes de escritura entre compra y venta. Es el banco de prueba de la inferencia
  de formatos: reutilizalo tal cual, no generes formatos nuevos en volumen.
- **`docs/ejemplos/01..05`** — factura simple, factura adjunta con CDATA, factura de
  4 productos con EAN, ventas en formato conocido, ventas en formato a aprender.

Estado actual de la base: un solo negocio de prueba, 64 movimientos, 4 productos,
cero terceros, cero conteos, cero facturas, cero alias. Los datos que hay ejercitan
la ingesta y no llegan a la analítica.

Sin resolver hoy, y por tanto parte del trabajo: no hay fixtures de terceros,
cartera, pagos ni conteos; la prueba "Inventario" del §7 del ROADMAP es la única de
las cuatro sin automatizar; no hay manifest de escenarios; no hay runner que corra
los bancos (se copia el comando de la cabecera de cada archivo);
`docs/ejemplos/historial_6meses/` y `dian_oficiales/` no están documentados en
ningún `.md`; y `ventas_202606_pos_semicolon.csv` está mal nombrado (usa comas).

---

## 3. Fuente UCI: entrada y decisiones sobre los datos crudos

Entrada por archivo local, sin descarga automática:

```
--input docs/ejemplos/fuente/online_retail_II.xlsx
```

Si no existe, mensaje claro indicando dónde ponerlo y de dónde bajarlo
(`https://archive.ics.uci.edu/dataset/502/online+retail+ii`). El dataset no se
versiona en el repo. Licencia CC BY 4.0: conservá la atribución en la documentación
y en el manifest.

Entorno: Python 3.14 sin `pandas`, `openpyxl` ni `psycopg2` instalados. El repo tiene
tradición de cero dependencias. Leé el `.xlsx` con stdlib (`zipfile` +
`xml.etree.iterparse` sobre `sharedStrings.xml` y la hoja), y aceptá también el CSV
equivalente.

Decisiones obligatorias, documentadas y explícitas:

- `Quantity < 0` e `InvoiceNo` con prefijo `C` son devoluciones y cancelaciones.
  Chasqui no tiene tipo para eso. Descartalas del flujo principal; reservá un
  subconjunto para el negocio de datos incompletos.
- `Description` NULL y `CustomerID` vacío (~25% de las filas): material natural para
  los escenarios de matching sucio.
- Precios en GBP: escalalos a pesos colombianos con un factor documentado. Los
  umbrales de priorización trabajan sobre `base_mes` en pesos; sin escalar, la
  relevancia de las recomendaciones no se parece a producción.
- Fechas: re-ancladas a `current_date` según C3.

Conservá de UCI: frecuencia de ventas, mezcla de productos, cantidades, dispersión de
precios, forma estacional y concentración tipo Pareto. No introduzcas patrones
perfectos: los datos base deben conservar la irregularidad real. Donde un escenario
exija una tendencia limpia, el manifest debe declarar la intervención.

---

## 4. Salidas

```
docs/ejemplos/
  fuente/            ← UCI original (gitignored)
  generados/         ← dataset generado (gitignored salvo manifests)
    <negocio>/
      ventas_YYYYMM.csv           cabecera de pos_csv_generico
      compra_YYYYMM_<prov>.xml    UBL 2.1
    manifests/
      scenarios.json
      oracle.json
```

Los bancos SQL van en `db/pruebas/`, junto a los tres existentes. Los ejemplos
curados actuales no se mueven ni se modifican.

---

## 5. Negocios sintéticos

Doce negocios completamente aislados. Una operación de uno jamás puede afectar los
resultados de otro. Cada uno con:

- `nombre` con prefijo `'PRUEBA GEN '` (la convención de los bancos existentes es
  `'PRUEBA '`)
- `plan = 'pro'` y `nit` válido con dígito de verificación
- un usuario con `autorizacion_datos = true` y `telegram_chat_id` en el rango
  `888xxx` (los bancos ya ocupan `999001` y `777001`)
- período histórico, catálogo, proveedores, ventas, compras, costos, inventario y
  eventos propios del escenario

| Negocio | Reglas que **deben** disparar | Reglas que **no** deben disparar |
|---|---|---|
| `saludable` | ninguna | todas |
| `margen_bajo` | `margen` | `costo`, `agota` |
| `costos_crecientes` | `costo`, `proveedor_sube` | `quieto` |
| `inventario_excesivo` | `quieto` | `agota` |
| `productos_agotandose` | `agota` | `quieto` |
| `proveedor_caro` | `proveedor` | `dependencia` |
| `ventas_decrecientes` | `sin_ventas`, `vs_ano_anterior` | `agota` |
| `ventas_crecientes` | ninguna de deterioro | `sin_ventas`, `vs_ano_anterior` |
| `estacional` | ninguna | `vs_ano_anterior`, `sin_ventas` |
| `datos_incompletos` | — (se mide por calidad de matching) | — |
| `multiples_proveedores` | `dependencia` | `proveedor` |
| `accion_exitosa` | `margen` en el primer tramo, cerrada con `resultado='positivo'` al final | — |

`estacional` es la prueba de **falso positivo**: una caída estacional legítima no
debe leerse como deterioro. Es tan importante como los escenarios positivos.

---

## 6. Ventas

Desde UCI hacia CSV con la cabecera exacta de `pos_csv_generico`:

```
fecha,producto,categoria,cantidad,precio_unitario,total
```

Un archivo por negocio por mes. Cero tokens de LLM.

Para probar la inferencia de formatos desconocidos, reutilizá los seis layouts de
`docs/ejemplos/historial_6meses/*.csv`: un archivo, una vez. No generes cabeceras
nuevas en volumen; cada huella desconocida es una llamada al LLM dentro de
wf_ingesta.

---

## 7. Compras: emisor UBL 2.1

Módulo que emite facturas DIAN sintéticas, una por compra, parseables por
`ingesta_parsear_dian`. Usá `docs/ejemplos/historial_6meses/compra_*.xml` como
plantilla y `docs/ejemplos/dian_oficiales/` como referencia de casos reales.

Requisitos estructurales:

- raíz `Invoice`; generá además algún `AttachedDocument` con el `Invoice` embebido en
  CDATA, que es lo que llega por correo en la vida real
- `AccountingSupplierParty` con `RegistrationName` y `CompanyID` (NIT del proveedor)
- `AccountingCustomerParty` con el NIT del negocio
- `InvoiceLine` con descripción, `StandardItemIdentification/ID` (EAN — siembra el
  catálogo por código de barras), cantidad con `@unitCode`, `LineExtensionAmount`,
  `Price/PriceAmount`
- `LegalMonetaryTotal/PayableAmount` y `TaxTotal/TaxAmount` que cuadren:
  `|Σ líneas + impuesto − PayableAmount| < 1`

Las compras se derivan de las ventas, nunca al azar: cantidad coherente con lo
vendido más el stock objetivo del escenario, y costo que sostenga el margen que el
escenario declara. Nunca se vende más de lo que entró, salvo en el escenario de stock
estimado contradicho, donde eso es exactamente el punto.

### Proveedores

Nombres inequívocamente sintéticos (`PROVEEDOR DEMO 001`, `PROVEEDOR DEMO 002`, …),
NIT sintético válido. Nunca nombres de empresas reales.

Comportamientos diferenciados: estable, creciente, barato, caro, volátil, dominante
(>50% del gasto, para `dependencia`) y uno que deja de usarse a mitad del período.

Para que `proveedor` dispare hace falta el mismo producto comprado a ≥2 proveedores
distintos. Para `proveedor_sube`, ≥3 subidas del mismo proveedor en el último año.

---

## 8. Inventario

Conteos por `portal_conteo_guardar()`. Cinco situaciones, cada una en un producto
identificable:

| Situación | `origen_stock` esperado |
|---|---|
| conteo reciente sin movimientos posteriores | `conteo` |
| conteo antiguo + compras/ventas posteriores | `calculado` |
| sin conteo | `estimado` |
| stock casi agotado | con `agota` disparando |
| exceso de stock | con `quieto` disparando |

Más un caso obligatorio: **un conteo posterior que contradice el stock estimado**,
para reproducir el problema de recomendaciones nacidas de una estimación. El oráculo
debe declarar cómo cambia la recomendación antes y después del conteo.

---

## 9. Cartera

Cuentas por cobrar con `portal_factura_guardar()` y `pago_registrar()`; cuentas por
pagar por XML DIAN.

Cinco casos: sin cartera, cartera al día, vencida, vencida con impacto relevante
(regla `cartera` disparando con mora >15 días), y pagada después — donde la
recomendación debe cerrar como `resuelta` con `cerrada_por='dato'`
(`recomendacion_objeto_evaluable` soporta `tercero:` justamente para eso).

Los vencimientos se calculan contra `current_date`, no contra el calendario del
dataset.

---

## 10. Motor de simulación temporal

Es la pieza central. Por cada negocio y por cada mes del período:

```
cargar ventas del mes    → ingesta_registrar_documento
                           → ingesta_identificar_tabular
                           → ingesta_cargar_tabular
cargar compras del mes   → ingesta_registrar_documento
                           → ingesta_procesar_documento
                             (→ ingesta_parsear_dian → cartera_facturar_dian)
resolver                 → match_resolver_documento
conteos y cartera        → portal_conteo_guardar / portal_factura_guardar /
                           pago_registrar
fotografiar              → snapshot_tomar(negocio, 'manual')
registrar                → recomendaciones_registrar(negocio)
medir                    → recomendaciones_medir(negocio)
```

Nada de INSERTs directos en `movimientos`: si cambia la ingesta, esto tiene que
romperse a la vista y no en silencio.

Acciones de usuario simuladas donde el escenario lo pida, vía
`recomendacion_accion(...)`.

Al final del recorrido completo, y solo entonces: `alertas_evaluar()` e
`informes_periodicos_disparar()`, teniendo en cuenta sus compuertas horarias.

---

## 11. Manifest de escenarios

`docs/ejemplos/generados/manifests/scenarios.json`. Por escenario: negocio, seed,
período, productos afectados, proveedores afectados, eventos generados, reglas que
deben activarse, reglas que no deben activarse, y estado esperado.

```json
{
  "escenario": "costos_crecientes",
  "negocio": "PRUEBA GEN costos_crecientes",
  "seed": 20260815,
  "periodo": {"desde": "...", "hasta": "..."},
  "productos": ["..."],
  "proveedores": ["PROVEEDOR DEMO 003"],
  "eventos": ["3 subidas de costo del proveedor 003 en 12 meses"],
  "reglas_esperadas": ["costo", "proveedor_sube"],
  "reglas_prohibidas": ["quieto", "agota"],
  "estado_esperado": {"recomendaciones.estado": "vigente"}
}
```

Usá los nombres reales de las once reglas. Nada de claves inventadas.

---

## 12. Oráculo independiente

`docs/ejemplos/generados/manifests/oracle.json`, calculado **en Python desde los
datos generados**, nunca replicando el SQL de Chasqui. Si el oráculo repite la misma
consulta, un mismo error pasa las dos pruebas.

Implementá cada umbral desde su definición, no desde su implementación:

```
costo:            (costo_final - costo_inicial) / costo_inicial >= 0.08
proveedor:        precio_pagado > min(precio_por_proveedor) * 1.05
margen:           (precio - costo) / precio * 100 < 20
agota:            balance / (unidades_vendidas / dias_ventana) < 7
quieto:           dias_desde_ultima_venta > 60 y balance > 0
dependencia:      gasto_proveedor / gasto_total > 0.50
sin_ventas:       dias_desde_ultima_venta > 45, ventas >= 3, span >= 14
proveedor_sube:   count(precio > previo * 1.01) >= 3 en 365 días
margen_cae:       margen[t] < margen[t-1] < margen[t-2], caída >= 3 pp
vs_ano_anterior:  (ventas_mes_ref - ventas_mismo_mes_ano_anterior) / anterior <= -0.15
cartera:          sum(saldo where vencimiento < hoy - 15d) > 0
```

La comparación es `ORÁCULO(datos)` contra `recomendaciones_negocio(negocio, true)`.

---

## 13. Perfiles y reproducibilidad

```
--profile small    3 negocios,   6 meses,   ~5.000 movimientos
--profile medium  12 negocios,  15 meses,  ~50.000 movimientos
--profile large   20 negocios,  24 meses, ~200.000 movimientos
```

`medium` es el perfil de referencia: 15 meses es el mínimo cómodo para
`vs_ano_anterior` (~13). Ajustá los números tras medir tiempos reales de ingesta;
recordá C5.

Los negocios deben tener variaciones reales entre sí; no dupliques las mismas filas.

`--seed` fija catálogos, calendario, cantidades, precios, proveedores y escenarios.
Como los IDs son `IDENTITY`, la reproducibilidad se verifica sobre **salida
normalizada**, enmascarando ids de secuencia y timestamps con la técnica de `_norm()`
en `db/pruebas/router_casos.sql`. Dos corridas con la misma seed dan salida
normalizada idéntica; una seed distinta da otro dataset válido.

---

## 14. Validación del dataset

`bin/validar_datos_prueba.py`, antes de tocar Chasqui:

1. sin IDs duplicados ni FKs imposibles
2. cantidades, precios y costos positivos y coherentes
3. las compras sostienen las ventas, salvo donde el escenario declara lo contrario
4. todo XML cuadra: `|Σ líneas + impuesto − PayableAmount| < 1`
5. fechas dentro del período declarado
6. ningún archivo de un negocio menciona productos o proveedores de otro
7. cada escenario contiene realmente las condiciones que declara, contra el oráculo
8. ≥13 meses en los negocios que declaran `vs_ano_anterior`
9. ningún documento supera el 20% de filas sin fecha o sin valor, salvo el diseñado
   para probar el rechazo
10. todos los negocios nacen con `plan='pro'` y NIT válido

No basta con comprobar que el archivo se generó.

---

## 15. Verificación contra Chasqui

`db/pruebas/escenarios_generados.sql`, en el estilo de los bancos existentes:
transacción con `ROLLBACK`, función `_chk`, salida `[PASS]/[FAIL]/[WARN]` por
escenario y conteo final.

Comprobaciones:

- cada escenario dispara sus `reglas_esperadas` y ninguna de sus `reglas_prohibidas`
- `estacional` no dispara `vs_ano_anterior` ni `sin_ventas`
- ciclo de resultado: una recomendación aparece → pasa a `vigente` → se cierra con
  `recomendacion_accion('hice')` → entran datos nuevos → `recomendaciones_medir` la
  clasifica `positivo`
- reglas comparativas: `margen_cae` dispara con dos snapshots no parciales;
  `vs_ano_anterior` con 13 meses de historia
- alertas: `alertas_evaluar()` emite una; la segunda corrida no la repite por
  cooldown; con datos nuevos y otra regla, emite una distinta
- informe periódico: `v_negocios_informe_periodico` no lista un negocio sin análisis
  previo, y sí lo lista con análisis + 30 días + ≥10 movimientos nuevos
- inventario: aparecen los tres `origen_stock`, y el conteo que contradice la
  estimación cambia la recomendación
- matching: las filas sin producto quedan con `producto_id NULL` y alias
  `pendiente`, no desaparecen; `alias_pendientes()` las reporta con la plata que
  representan; `match_confirmar_alias` cambia los resultados retroactivamente
- aislamiento: para cada par de negocios, ninguna vista, recomendación, snapshot,
  alerta ni resultado de uno referencia objetos del otro. Atención especial a
  cualquier JOIN por `producto_id` sin `negocio_id`

Además, **una** corrida real de `wf_ejecutar` sobre un negocio generado, para
confirmar que la cadena completa produce informe y que las cifras pasan
`validar_cifras`. El resto del ciclo se simula por SQL, sin gastar tokens.

---

## 16. Entregables

1. `bin/gen_datos_prueba.py` — generador
2. `bin/cargar_datos_prueba.py` — motor de simulación temporal (§10)
3. `bin/validar_datos_prueba.py` — validación del dataset y oráculo
4. `db/pruebas/escenarios_generados.sql` — banco de verificación
5. `bin/pruebas.sh` — runner de los cuatro bancos
6. `docs/TEST_DATA_GENERATOR.md`
7. `docs/ejemplos/generados/manifests/{scenarios,oracle}.json`
8. instrucciones exactas de ejecución

`docs/TEST_DATA_GENERATOR.md` documenta: estructura real de entrada de Chasqui,
estructura de salida, transformación UCI → Chasqui (incluidos el factor GBP→COP y el
re-anclaje de fechas), datos sintéticos agregados, escenarios con sus reglas, seed y
reproducibilidad por salida normalizada, comandos de ejecución, invariantes,
atribución CC BY 4.0 y limitaciones.

Aprovechá para documentar `docs/ejemplos/historial_6meses/` y `dian_oficiales/`, hoy
sin descripción en ningún `.md`, y corregí el nombre de
`ventas_202606_pos_semicolon.csv`, que usa comas y no punto y coma.

Ejemplo conceptual de invocación:

```bash
python3 bin/gen_datos_prueba.py \
  --input docs/ejemplos/fuente/online_retail_II.xlsx \
  --output docs/ejemplos/generados \
  --profile medium --seed 20260815
```

---

## 17. Restricciones

No modifiques: lógica de negocio, reglas, snapshots, consultas, router, workflows,
prompts ni migraciones productivas. No crees una segunda implementación de Chasqui.
No modifiques wf_ingesta para acomodar el dataset. No hagas INSERTs directos en
`movimientos`. No introduzcas llamadas a LLM en el generador ni dependas de un LLM
para decidir qué datos generar. No uses nombres de empresas reales ni datos que
parezcan de personas identificables. No descargues nada automáticamente.

No declares terminado nada que no haya corrido: generar el perfil `small`, validarlo,
cargarlo por la ruta real de ingesta, ejecutar el banco de escenarios, y una corrida
de `wf_ejecutar`.

Si al implementar descubrís que algo de este documento no coincide con el código
real, documentá la discrepancia y adaptá el generador a la implementación real, no al
revés.

---

## 18. Informe final

Al terminar, entregá: datos reales utilizados · estructura real descubierta ·
transformaciones · datos sintéticos generados · escenarios · oráculo · pruebas
ejecutadas · resultados · limitaciones · riesgos abiertos.
