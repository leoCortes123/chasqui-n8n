---
name: jsonb-build-object-literales-postgres
description: "jsonb_build_object('k','{}') crea el string \"{}\", no un objeto — exige ::jsonb"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 461cfd50-55b8-4a2d-8bd8-f8cee5731c22
  modified: 2026-07-25T13:47:32.445Z
---

En `jsonb_build_object(...)` los literales van como `text`, no como jsonb: Postgres solo
infiere jsonb cuando el literal se compara o asigna contra algo jsonb.

```sql
jsonb_build_object('vars','{}')        -- {"vars": "{}"}  string JSON
jsonb_build_object('vars','{}'::jsonb) -- {"vars": {}}    objeto
```

Rompió el router de Chasqui: `jsonb_each_text` sobre `'"{}"'::jsonb` aborta con
*cannot call jsonb_each_text on a non-object*, y en JS `for (const a of "[]")` itera
caracteres en silencio en vez de un array vacío. Arreglado en
`docs/historico/migraciones/016_fix_jsonb_literales.sql` (literales + `resolver_plantilla` blindada
con `jsonb_typeof(p_vars) = 'object'`). Las migraciones 012/014/015 quedaron con el
literal malo a propósito: no se editan migraciones ya aplicadas.

**How to apply:** al escribir SQL que arma jsonb para n8n, castear `::jsonb` todo
literal `'{}'`/`'[]'`, y no confiar en `x || []` de JS para tapar el error — un string
es truthy. Ver [[proyecto-chasqui-n8n]].
