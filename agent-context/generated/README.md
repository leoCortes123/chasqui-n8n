# generated/ — metadatos derivados del código

Regenerar con:

```bash
python3 bin/gen_agent_context.py
```

No editar a mano. No contiene opiniones: todo se deriva de fuentes ya generadas
del repo (`db/actual/INDICE.md`, `db/actual/grafo.json`, `workflows/wf_*.json`,
`db/actual/MANIFIESTO.txt`), sin consultar la base.

| Archivo | Contenido | Fuente |
|---|---|---|
| `symbols.json` | 160 funciones: firma, archivo, `calls`/`called_by_sql`, `entry_points` (n8n/scripts), tablas usadas, sobrecargas | grafo.json + INDICE.md |
| `dependencies.json` | tabla/vista → funciones que la referencian; workflow → funciones que llama directo | grafo.json |
| `workflows.json` | inventario por workflow: nodos (nombre/tipo), sub-workflows, funciones SQL detectadas por regex (informativo, no exhaustivo — el despacho dinámico por filas no es estático) | wf_*.json |
| `database.json` | conteos y listas de tablas/vistas/funciones; filas de contenido | INDICE.md + MANIFIESTO.txt |

Limitaciones declaradas (no inventadas):

- Las relaciones son **referencias textuales**; no distinguen lectura de escritura.
- Los enums NO están volcados en `db/actual/` (deuda D-010): ver
  `db/base/000_esquema.sql` sabiendo que está congelado en v0.
- `active: false` en los JSON del repo no refleja el estado vivo de n8n.
