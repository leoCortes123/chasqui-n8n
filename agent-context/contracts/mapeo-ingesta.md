---
id: CONTRACT-MAPEO-INGESTA
type: contract
status: active
provider: ingesta_identificar_tabular / formatos_documento (SQL)
consumers: [wf_ingesta (nodo InferirMapeo), LLM técnico, DOMAIN-INGESTA]
---

# Mapeo de columnas: n8n ↔ SQL ↔ LLM

**Propósito**: contrato de `INGESTA-001`. El modelo puede devolver un **mapeo de
nombres de columna**, jamás cifras. Postgres carga todas las filas con ese mapeo.

## Entrada al modelo (prompt `prompts_tecnicos` clave `ingesta.inferir_mapeo`)

```jsonc
{ "columnas": ["Fecha Venta", "Producto", ...],   // nombres reales, normalizados
  "muestra": [ {...5 filas...} ] }                 // NUNCA el archivo completo
```
Sustitución por nodos Code (`{{columnas}}`, `{{muestra}}`). Sólo se llama si
`NOT (v_cols ? 'fecha') OR NOT v_tiene_valor` tras el diccionario.

## Respuesta esperada

```jsonc
{ "tipo": "venta|compra", "decimal": ",", "miles": ".",
  "formato_fecha": "DD/MM/YYYY",
  "columnas": { "fecha": "Fecha Venta", "producto": "...",
                "cantidad|valor_total|valor_unitario|codigo|categoria|unidad|impuesto": "..." } }
// o { "error": "faltan columnas obligatorias" }
```

## Validación en SQL (`ingesta_registrar_formato_inferido`) `[CONFIRMADO]`

- `error` en el JSON ⇒ documento a estado `error`.
- `columnas` no objeto ⇒ `error`.
- **Filtra a las 9 claves canónicas** (CHECK en `sinonimos_columna`) y descarta
  cualquier valor que no exista como columna real del archivo.
- Exige `fecha` y (`valor_total` o `valor_unitario`); si no ⇒ `error`.
⇒ El modelo no puede inventar columnas ni cargar sin fecha/valor.

## Persistencia y reuso

- Formato guardado en `formatos_documento` con `huella = md5(cabeceras
  normalizadas+ordenadas)`; siguiente archivo del mismo POS = 0 tokens.
- Los DOS caminos sin-modelo y con-modelo escriben `origen='inferido'`
  (se distinguen sólo por `nombre`) — DISC-D4.
- Aprendidos de un cliente **no entran al baseline** (`BASE-001`,
  verificar.sh chequeo 8).

## Compuerta de carga (posterior al mapeo)

`ingesta_cargar_tabular_detalle`: >20% filas sin fecha o sin valor ⇒
`documentos.estado='error'` con motivo que nombra la columna, **cero filas
insertadas**. Archivo agregado (valor sin producto/cantidad) ⇒ `descartado`,
sin aviso.

## Tests

`db/pruebas/ingesta_sin_modelo.sql` (48 comprobaciones con cabeceras reales;
el caso `cierre_caja` es la regresión del doble conteo). 1 aserción vieja
espera `error` donde hoy hay `descartado` (DISC-T2).
