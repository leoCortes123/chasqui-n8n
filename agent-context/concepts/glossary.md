---
id: CONCEPTS-GLOSSARY
type: glossary
status: active
---

# Glosario canónico

Vocabulario del sistema, definido por lo que hace el código (no por el nombre).
Definiciones en prosa extendida: `../../agent-context/reference/glosario-de-negocio.md`.
Si un concepto tiene dos nombres en el repo, se registra la discrepancia al pie.

```yaml
- id: CONCEPT-NEGOCIO
  name: negocio
  type: business-concept
  status: active
  definition: unidad de aislamiento; toda tabla de datos cuelga de negocios.id
  stored_in: negocios
  created_by: usuario_de_canal (automático, primer mensaje)
  consumed_by: [todo el análisis, portal_claim]
  related: [CONCEPT-USUARIO, CONCEPT-PLAN]

- id: CONCEPT-USUARIO
  name: usuario / identidad
  type: business-concept
  status: active
  definition: usuarios es la persona; identidades su cuenta por canal (UNIQUE canal+id_externo). telegram_* en usuarios es el modelo anterior, aún poblado en paralelo
  related: [CONCEPT-NEGOCIO]
  discrepancy: DUP-1 (dos modelos conviviendo)

- id: CONCEPT-SESION
  name: sesión
  type: business-concept
  status: active
  definition: conversación con objetivo; estados intake→recibiendo→procesando→completada|fallida|expirada; consulta nace en procesando y muere con su ejecución
  stored_in: sesiones

- id: CONCEPT-SERVICIO
  name: servicio
  type: business-concept
  status: active
  definition: fila de servicios; declara funcion_hallazgos (despacho dinámico) y entrada (archivos|texto). Hoy 3 activos
  stored_in: servicios
  related: [CONTRACT-HALLAZGOS-PROMPT]

- id: CONCEPT-MODULO
  name: módulo
  type: business-concept
  status: active
  definition: agrupador de servicios para el menú; con uno solo activo teclado_intake salta directo

- id: CONCEPT-DOCUMENTO
  name: documento
  type: business-concept
  status: active
  definition: archivo del usuario guardado íntegro (bytea); identidad sha256 dentro del negocio; estados pendiente→parseado|error|descartado
  stored_in: documentos
  discrepancy: 'descartado' no existe en db/base/000_esquema.sql (D-010)

- id: CONCEPT-DESCARTADO
  name: descartado
  type: business-concept
  status: active
  definition: el sistema entendió el archivo y decidió NO cargarlo (único caso hoy tabla agregada); no es error y no avisa (migración 075)

- id: CONCEPT-FORMATO
  name: formato
  type: business-concept
  status: active
  definition: fila de formatos_documento; clase documento=parsea Postgres solo (hoy sólo dian_xml); clase tabular=n8n extrae filas primero
  related: [CONCEPT-HUELLA, CONTRACT-MAPEO-INGESTA]

- id: CONCEPT-HUELLA
  name: huella
  type: business-concept
  status: active
  definition: md5 de cabeceras normalizadas+deduplicadas+ordenadas; identidad de un layout; mismo POS ⇒ misma huella aunque cambie el orden de columnas

- id: CONCEPT-MAPEO
  name: mapeo
  type: business-concept
  status: active
  definition: jsonb que dice qué columna del archivo es cada concepto canónico (9 fijos por CHECK) + tipo/decimal/miles/formato_fecha/agregado
  related: [CONTRACT-MAPEO-INGESTA]

- id: CONCEPT-AGREGADO
  name: agregado
  type: business-concept
  status: active
  definition: archivo con valor pero sin producto ni cantidad; resumen, no detalle ⇒ descartado

- id: CONCEPT-MOVIMIENTO
  name: movimiento
  type: business-concept
  status: active
  definition: línea de compra/venta normalizada; raw guarda la original; proveedor aquí es texto libre raw->>'proveedor'
  discrepancy: DUP-2 (proveedor texto vs tercero_id sin conciliar)

- id: CONCEPT-ALIAS
  name: alias
  type: business-concept
  status: active
  definition: texto de producto visto en archivo, normalizado; con producto_id=resuelto, sin él=pendiente para portal

- id: CONCEPT-MATCHING
  name: matching
  type: business-concept
  status: active
  definition: cascada código de barras → alias exacto → trigram ≥0,45 → pendiente; nunca inventa producto sin código

- id: CONCEPT-TERCERO
  name: tercero
  type: business-concept
  status: active
  definition: proveedor/cliente identificado, sólo ruta DIAN; dedupe por NIT o nombre normalizado

- id: CONCEPT-EJECUCION
  name: ejecución
  type: business-concept
  status: active
  definition: corrida de análisis; guarda hallazgos exactos y texto entregado (snapshot inmutable)

- id: CONCEPT-HALLAZGOS
  name: hallazgos
  type: business-concept
  status: active
  definition: jsonb que ejecucion_preparar entrega al modelo; TODO lo que el modelo ve del negocio; forma según servicio
  related: [CONTRACT-HALLAZGOS-PROMPT]

- id: CONCEPT-SALUD
  name: salud
  type: business-concept
  status: active
  definition: seis notas 0-100 + índice = promedio de las no nulas; NULL entera si las seis son nulas
  source_decision: HALLAZGOS-001

- id: CONCEPT-RECOMENDACION
  name: recomendación
  type: business-concept
  status: active
  definition: problema detectado por una de las 11 reglas, con impacto $ y opciones redactados por SQL; persiste tras el informe
  source_decision: CORE-003

- id: CONCEPT-IMPACTO
  name: impacto / tipo de impacto
  type: business-concept
  status: active
  definition: impacto_mes=pesos; impacto_tipo=mensual|unico|capital, cada uno con sus umbrales de prioridad propios

- id: CONCEPT-RELEVANCIA
  name: relevancia / base mes
  type: business-concept
  status: active
  definition: relevancia=pct/umbral_media_de_su_tipo (única comparable entre tipos); base_mes=greatest(ventas,compras)/meses min 1

- id: CONCEPT-DETECTADO-VS-MOSTRADO
  name: detectado vs mostrado
  type: business-concept
  status: active
  definition: p_registro=true devuelve todo; modo informe top máx 2/regla y 8 total; existe para no cerrar como resuelta algo fuera del top

- id: CONCEPT-SNAPSHOT
  name: snapshot
  type: business-concept
  status: active
  definition: foto diaria (1/día, segunda pisa primera) con TODOS los productos, umbrales congelados y calidad; NULL si no hay movimientos fechados

- id: CONCEPT-CONOCIMIENTO
  name: conocimiento
  type: business-concept
  status: active
  definition: hechos escritos por una persona (/saber, portal, aplicar precio); búsqueda trigram umbral 0,12; NO es RAG ni memoria conversacional
  related: [CONCEPT-PENDIENTE]

- id: CONCEPT-PENDIENTE
  name: pendiente de conocimiento
  type: business-concept
  status: active
  definition: pregunta que el bot no supo responder, contador veces; alimenta el portal

- id: CONCEPT-PLAN
  name: plan
  type: business-concept
  status: active
  definition: free limita LECTURA a plan_free_meses_historia (3) vía plan_desde+mov_visibles; nunca borra (CORE-002)

- id: CONCEPT-CUPO
  name: cupo
  type: business-concept
  status: active
  definition: cupo_tokens_mes por negocio; bloquea la ejecución sin gastar tokens
  discrepancy: cupo=0 tiene dos lecturas opuestas (DISC-A1)

- id: CONCEPT-ORIGEN-STOCK
  name: origen del stock
  type: business-concept
  status: active
  definition: conteo | calculado | estimado; viaja hasta el texto del usuario
  source_decision: DATOS-001

- id: CONCEPT-INFORME-SECO
  name: informe seco
  type: business-concept
  status: active
  definition: informe sin narración del modelo, misma renderización; entrega válida cuando el LLM falla dos veces

- id: CONCEPT-PANEL
  name: panel de carga
  type: business-concept
  status: active
  definition: único mensaje por sesión que se edita y fija; modos panel/esperando/analizando
  source_decision: INGESTA-002

- id: CONCEPT-COOLDOWN
  name: cooldown de alerta
  type: business-concept
  status: active
  definition: alerta_cooldown_dias (14) por par (regla, clave_objeto)
  warning: limita por CORRIDA, no por día (RI-11)
```

## Nombres duplicados registrados

| Concepto | Nombres en colisión | Dónde |
|---|---|---|
| identidad de persona | `usuarios.telegram_*` vs `identidades` | DISC-D1 |
| proveedor | `raw->>'proveedor'` (reglas) vs `terceros` (DIAN/cartera) | DISC-D2 |
| formato aprendido sin/con modelo | ambos `origen='inferido'` | DISC-D4 |
| "hoy" del análisis | `max(fecha)` vs `current_date` | DISC-D5 |
| menú de servicios | `teclado_intake()` — `teclado_servicios()` no existe desde la `057` | DISC-C1, corregido |
