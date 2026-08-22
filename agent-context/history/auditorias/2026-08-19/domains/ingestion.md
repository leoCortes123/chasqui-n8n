# Dominio: ingestión

De que el usuario suelta un archivo en el chat hasta que hay filas en
`movimientos` con producto resuelto.

## Responsabilidades

Guardar el original, decidir si sabe leerlo, extraer la tabla, identificar el
layout, mapear columnas, convertir cifras y fechas, insertar movimientos,
resolver productos, y contar todo en **un** panel.

## Entradas / salidas

| | |
|---|---|
| Entrada | binario de Telegram (`file_id`) o de WhatsApp (media id), con `sesion_id` |
| Salida | `documentos` (siempre), `movimientos`, `productos`, `alias`, `terceros`, `facturas`; y una acción `panel` / `analizar` |
| Workflow | `wf_ingesta` (34 nodos) · `bin/gen_wf_ingesta.py` |
| Funciones | 22 `ingesta_*`, 3 `match_*`, 7 `carga_*`, `cartera_facturar_dian`, `tercero_obtener` |
| Tablas | `documentos`, `formatos_documento`, `sinonimos_columna`, `movimientos`, `productos`, `alias`, `terceros`, `facturas`, `sesiones` |
| Decisiones | `INGESTA-001`, `INGESTA-002`, `DATOS-001`, `CORE-002` |

## Flujo, paso a paso `[CONFIRMADO]`

```mermaid
sequenceDiagram
    autonumber
    participant U as Usuario
    participant TG as Telegram
    participant R as wf_router
    participant PG as Postgres
    participant I as wf_ingesta
    participant LLM as LLM
    participant E as wf_enviar
    participant J as wf_ejecutar

    U->>TG: archivo
    TG->>R: webhook
    R->>PG: router_marcar_editables(router_procesar_mensaje(ev), ev)
    Note over PG: tiene_doc=true -> acción {tipo:'ingerir', sesion_id}<br/>incluso si la sesión está 'procesando' (INGESTA-002)
    R->>I: executeWorkflow (espera)
    I->>TG: getFile + descarga (3 reintentos, 2 s)
    alt no baja
        I->>PG: carga_registrar_fallo(sesion, nombre)
        Note over PG: se anota en sesiones.contexto.descargas_fallidas<br/>ÚNICO caso en que se pide reenviar
    end
    I->>PG: ingesta_registrar_documento(sesion, negocio, nombre, mime, bytea)
    Note over PG: hash sha256; ON CONFLICT (negocio_id,hash) DO UPDATE sesion_id
    alt formato clase='documento' (dian_xml)
        I->>PG: ingesta_procesar_documento -> ingesta_parsear_dian
        PG->>PG: XMLTABLE -> movimientos (tipo provisional 'compra')
        PG->>PG: cartera_facturar_dian -> facturas + terceros + UPDATE tipo
    else tabular
        I->>I: DetectarSeparador (JS) / ExtraerCSV o ExtraerHoja
        I->>I: AgruparFilas -> columnas, muestra(5), muestra_amplia(100)
        I->>PG: ingesta_identificar_tabular(doc, columnas, muestra_amplia)
        alt huella conocida
            PG-->>I: requiere_inferencia=false, origen='cache'
        else diccionario resuelve
            PG->>PG: ingesta_inferir_mapeo_sql -> ingesta_registrar_formato_resuelto
            PG-->>I: requiere_inferencia=false
        else ni fecha ni valor reconocidos
            PG-->>I: requiere_inferencia=true
            I->>LLM: solo nombres de columna + 5 filas
            LLM-->>I: JSON de mapeo
            I->>PG: ingesta_registrar_formato_inferido(doc, columnas, mapeo)
        end
        I->>PG: ingesta_cargar_tabular(doc, filas)
    end
    I->>PG: match_resolver_documento(doc) + ingesta_resumen_documento(doc)
    I->>I: Esperar 11 s
    I->>PG: carga_evaluar(sesion)
    alt 'panel'
        I->>E: refrescar panel
    else 'analizar'
        I->>E: panel modo 'analizando'
        I->>J: waitForSubWorkflow=false
    else 'nada'
        Note over I: otra ejecución más nueva decide
    end
```

## Registro y deduplicación

`[CONFIRMADO]` `ingesta_registrar_documento`:

1. Busca formato `clase='documento'` por `mime` o extensión → hoy sólo
   `dian_xml`.
2. Si no, busca la extensión en `parametros.ingesta_extractores`:
   `{"csv":"csv","ods":"ods","tsv":"csv","txt":"csv","xls":"xls","xlsx":"xlsx"}`.
3. **Siempre inserta** la fila en `documentos` con el bytea, antes de decidir
   nada. `ON CONFLICT (negocio_id, hash)` reasigna la sesión.
4. Si ni formato ni extractor: marca `error` con
   `«no sé leer archivos <ext>»` y devuelve `reconocido: false`.

`[CONFIRMADO]` Consecuencia de (3): **el archivo nunca se pierde**, aunque no se
pueda leer. `INGESTA-002` cumplido.

## Identificación de layout — el camino de tres escalones

`[CONFIRMADO]` `ingesta_identificar_tabular`:

| Escalón | Función | Costo | Resultado |
|---|---|---|---|
| (a) huella conocida | `SELECT ... WHERE huella = ingesta_huella(cols)` | 0 | `origen='cache'` |
| (b) diccionario | `ingesta_inferir_mapeo_sql` → `ingesta_resolver_columnas` (44 patrones regex en `sinonimos_columna`) + `ingesta_inferir_decimales` + `ingesta_inferir_formato_fecha` | 0 | `origen='sql'` |
| (c) modelo | prompt `ingesta.inferir_mapeo` | 1 llamada | `origen='modelo'` |

`[CONFIRMADO]` (c) sólo se alcanza si **no** se reconoció la fecha **o** no se
reconoció ningún valor. Es literalmente el `IF NOT (v_cols ? 'fecha') OR NOT
v_tiene_valor`.

`[CONFIRMADO]` **El modelo nunca ve cifras del archivo completo**: `ArmarMapeo`
manda `columnas` y `muestra` (5 filas). `INGESTA-001` cumplido.

`[CONTRADICCIÓN]` Los dos caminos que persisten un formato nuevo escriben
`origen = 'inferido'`: `ingesta_registrar_formato_resuelto` (que **no** usó el
modelo) e `ingesta_registrar_formato_inferido` (que sí). Sólo se distinguen por
el `nombre`: `'Tabla reconocida/agregada (csv)'` vs `'Tabla inferida (csv)'`.
Consultar `formatos_documento.origen` **no** dice si costó una llamada al
modelo. Las dos filas aprendidas en esta base son `'Tabla agregada'` y
`'Tabla reconocida'`: **ninguna** de las dos gastó tokens.

## Carga y compuerta de calidad

`[CONFIRMADO]` `ingesta_cargar_tabular`:

- Si `mapeo.agregado = true` → `ingesta_marcar_descartado` con motivo explícito.
  **No** es error y **no** genera aviso al usuario (migración 075).
- Si no, `ingesta_cargar_tabular_detalle`.

`[CONFIRMADO]` `ingesta_cargar_tabular_detalle` mide **antes de insertar**:

```
pct_sin_fecha = filas sin fecha parseable / total
pct_sin_valor = filas sin valor_total NI valor_unitario / total
max_pct_nulos = mapeo->>'max_pct_nulos'  (default 20)
pasa = n > 0 AND pct_sin_fecha <= 20 AND pct_sin_valor <= 20
```

Si no pasa: `documentos.estado='error'` con un motivo que **nombra la columna y
el formato** y **no se inserta ni una fila**. Es `INGESTA-001` invariante 2.

`[CONFIRMADO]` Derivación de cifras cuando falta una:
`valor_unitario ← valor_total / cantidad` y `valor_total ← valor_unitario ×
cantidad`. Ninguna la hace el modelo.

## Ventana del plan

`[CONFIRMADO]` `trg_movimientos_limite_plan` **no bloquea nada**: cuenta la fila
en `documentos.filas_fuera_de_plan` y la inserta igual. El plan sólo filtra
lectura, en `mov_visibles`. `CORE-002` cumplido y comprobable.

## Matching

`[CONFIRMADO]` `match_resolver_documento` recorre `movimientos WHERE
documento_id = X AND producto_id IS NULL`, fila por fila (bucle `FOR`, no set):

1. Con `raw->>'codigo'`: busca `productos.codigo_barras`; si no existe **crea el
   producto** y memoriza el texto como alias `exacto`.
2. Sin código: `match_resolver_producto` — alias exacto → trigram ≥ 0,45
   (auto-confirma y memoriza) → alias `pendiente` sin producto.

`[CONFIRMADO]` Falla registrada hoy en `fallas`:
`duplicate key value violates unique constraint "uq_producto_barras"` en
`wf_ingesta`, 2026-08-19 13:07:47. Es la carrera entre ejecuciones concurrentes
que insertan el mismo `codigo_barras` (`N8N_CONCURRENCY=5`): el `SELECT`
seguido de `INSERT` no es atómico y no hay `ON CONFLICT`. Hallazgo A-04.

## DIAN

`[CONFIRMADO]` `ingesta_parsear_dian` soporta `Invoice`, `CreditNote`,
`DebitNote` y desenvuelve `AttachedDocument` (CDATA). Inserta las líneas como
`tipo='compra'` **provisional** y devuelve un campo `cuadra` que compara
`suma_lineas + impuesto` contra `PayableAmount` con tolerancia < 1.

`[CONFIRMADO]` `cartera_facturar_dian` decide el lado del mostrador comparando
`negocios.nit` contra el `CompanyID` del emisor. **`negocios.nit` es NULL en
esta instalación**, así que la rama `venta` es inalcanzable y toda factura entra
como compra. `[INFERIDO]` Consecuencia: sin NIT no hay cartera por cobrar, y por
tanto la nota de liquidez del semáforo es siempre `NULL` y la regla `cartera`
nunca dispara. Se comprobó: `salud_negocio(55)` no trae clave `liquidez`.

`[CONFIRMADO]` `cuadra` se calcula y **nadie lo consume**: `ingesta_parsear_dian`
lo devuelve en su JSON, que `ingesta_procesar_documento` propaga hasta el nodo
`Procesar` de n8n, donde muere. No hay validación de que la factura cuadre.

## El panel (INGESTA-002)

`[CONFIRMADO]` Todos los caminos —éxito, formato desconocido, error de parseo,
descarga fallida, insert fallido— confluyen en el nodo `Sesion` → `Esperar 11 s`
→ `carga_evaluar`. No hay un mensaje por archivo.

`carga_evaluar` con lock por sesión decide:

| Condición | Devuelve |
|---|---|
| sesión inexistente o cerrada | `nada` |
| último documento hace < 10 s | `nada` (el que entre después decide) |
| panel en vuelo (`panel_pedido_en` puesto, `panel_mensaje_id` NULL, < 30 s) | `nada` |
| silencio + `analisis_pedido_en` + `estado='recibiendo'` + hay parseados | `analizar` + crea ejecución |
| silencio + `analisis_pedido_en` + **sin** parseados | `panel` |
| silencio, nadie pidió nada, `estado='recibiendo'` | `panel` |

`[CONFIRMADO]` `carga_arrancar` es el punto de serialización final: el
`UPDATE ... WHERE estado='recibiendo'` con `RETURNING` devuelve NULL si otro
llegó primero, y entonces `carga_evaluar` devuelve `nada`. **Sólo puede haber
una ejecución por sesión.**

## Estados y recuperación

| Situación | Qué queda | Cómo se recupera |
|---|---|---|
| No baja de Telegram | nada en `documentos` | el panel lo nombra y pide reenviar — único reenvío que el sistema pide |
| INSERT falla | nada | `carga_registrar_fallo`, el panel lo nombra |
| Extensión desconocida | `documentos.estado='error'` con motivo | el panel lo cuenta como «no los pude leer» |
| Mapeo inválido | `error` con motivo que nombra la columna | reenviar con otro formato, o corregir el mapeo por migración |
| Archivo agregado | `descartado` con motivo | nada que hacer, es correcto |
| Producto sin resolver | `alias.producto_id IS NULL` | portal, pestaña Ventas → `portal_alias_confirmar` |
| Ejecución colgada > 15 min | `ejecuciones.estado='fallida'` + sesión `fallida` | `mantenimiento_ciclo` avisa con `ejecucion.fallida` |
| Sesión abandonada > 24 h | `expirada` | recordatorio único `sesion.recordatorio` |

`[CONFIRMADO]` **No hay reintento automático de un documento en error.** El
único reintento del dominio es el HTTP (`retryOnFail` en la descarga y en la
llamada al modelo).

`[CONTRADICCIÓN]` Cerrar la sesión (`/cancelar`, expiración, o el cierre que
hace `ejecucion_cerrar`) **abandona los documentos ya subidos**: quedan con
`sesion_id` apuntando a una sesión cerrada y ninguna ruta los recupera para la
sesión siguiente. Es lo que se ve en esta base: sesión 1 `expirada` con 96
documentos parseados y 37.454 movimientos, y sesión 2 `recibiendo` vacía. Los
datos **sí** están en `movimientos` y los ve cualquier análisis futuro
(`carga_hay_con_que` sólo mira `documentos` de **esa** sesión, salvo para
`mercado_compras`). Hallazgo A-06.

## Funciones del dominio sin llamador conocido

`[CONFIRMADO]` (coincide con `decisiones/deuda.md` D-006):

| Función | Estado |
|---|---|
| `ingesta_cargar_inventario` | referenciada por `formatos_documento.funcion_parseo` de `inventario_csv`, pero `ingesta_procesar_documento` corta antes por `clase='tabular'` y `wf_ingesta` llama siempre a `ingesta_cargar_tabular`. **No hay ruta que la alcance desde el chat.** |
| `ingesta_resumen_sesion` | ninguna función ni workflow la invoca; el panel usa `carga_resumen` |
| `usuario_de_telegram` | superada por `usuario_de_canal`; sin llamador |
| `ingesta_marcar_descartado` | sí se usa (`ingesta_cargar_tabular`) |
