---
id: CAND-073
dominio: ingesta
estado: candidato
titulo: 073_ingesta_sin_modelo.sql — la inferencia de formatos deja de gastar tokens
invariantes: []          # llenar a mano al promover
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: []
implementada_en: [docs/historico/migraciones/073_ingesta_sin_modelo.sql]
afecta:
  - ingesta_cargar_tabular
  - ingesta_cargar_tabular_detalle
  - ingesta_es_agregado
  - ingesta_identificar_tabular   # ya no existe en db/actual/
  - ingesta_inferir_decimales
  - ingesta_inferir_formato_fecha
  - ingesta_inferir_mapeo_sql
  - ingesta_inferir_tipo
  - ingesta_registrar_formato_inferido
  - ingesta_registrar_formato_resuelto
  - ingesta_resolver_columnas
  - sinonimos_columna   # ya no existe en db/actual/
procedencia: cabecera de docs/historico/migraciones/073_ingesta_sin_modelo.sql, commit sin commit (migración aún no versionada)
---

> **Candidato, no decisión.** Extraído automáticamente el 2026-08-18.
> Nada de acá gobierna hasta que se revise, se le fije estado y se
> mueva a `decisiones/`.

## Cabecera completa, textual

```
073_ingesta_sin_modelo.sql — la inferencia de formatos deja de gastar tokens.

Qué estaba mal (medido, no teórico):

1. Cada huella nueva costaba una llamada al modelo para resolver algo que
es casi todo determinista. Corrido `norm_texto` sobre las cabeceras
reales de la prueba de usuario, SEIS de las ocho columnas caen solas:

Fecha          -> fecha            (exacto)
Producto       -> producto         (exacto)
Categoria      -> categoria        (exacto)
Cantidad       -> cantidad         (exacto)
Valor_Unitario -> valor_unitario   (exacto)
Unidad         -> unidad           (exacto)
Total_Linea    -> valor_total      (sinónimo ^total)
Codigo_Barras  -> codigo           (sinónimo ^codigo)

Se le pagaron 4.000 tokens a un modelo para que hiciera un lower() con
guiones bajos. Con cupo de 20 peticiones diarias, diez archivos se
llevaron media jornada de cuota en trabajo redundante.

2. El modelo APRENDIÓ MAL un formato y nadie lo atrapó. El mapeo inferido
para los `cierre_caja` fue:

{"tipo":"venta","columnas":{"fecha":"Fecha","valor_total":"Total_Ventas"}}

Sin `producto` y sin `cantidad`: eso no es un libro de movimientos, es
un agregado diario. Se cargó como ventas individuales y quedó sumado
ENCIMA del detalle que ya venía en los otros archivos. Ese mapeo es la
causa exacta del doble conteo: 21.912 filas de detalle por $208.899.280
más 122 filas de cierre por $288.037.120 = $496.936.400 de ventas que el
negocio nunca hizo.

Un modelo no va a atrapar eso de forma confiable, porque "Total_Ventas"
PARECE una venta. Una regla sí.

Cómo queda:

huella conocida ─────────────────────────────────────────► cargar   (0 llamadas)
huella nueva → resolver determinista
├─ fecha + valor + (producto|cantidad) → cargar   (0 llamadas)
├─ fecha + valor, sin producto NI cantidad → agregado: se
│    aprende el formato y se rechaza con motivo     (0 llamadas)
└─ falta fecha o falta valor ───────────► el modelo, y solo
entonces                                       (1 llamada)

El modelo queda para lo que es genuinamente lingüístico: narrar el informe y
contestar preguntas libres. La compuerta de agregados se aplica también al
camino del modelo, así que ya no puede volver a envenenar `movimientos`.

=== 1. Diccionario de sinónimos de columna ================================
Una tabla, no un CASE: agregar el POS del próximo cliente es un INSERT, y se
puede hacer sin migrar. `patron` es una regex sobre norm_texto(), que ya
baja a minúsculas y quita acentos (004).

`prioridad` resuelve los choques: menor gana. Existe porque "Unidades" es
cantidad y "Unidad" es unidad de medida, y una sola pasada de regex no
distingue eso sin un orden explícito.
```
