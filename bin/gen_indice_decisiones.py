#!/usr/bin/env python3
"""Genera decisiones/INDICE.md. No editar el índice a mano: se sobrescribe."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from mcp_decisiones import cargar, DECISIONES  # noqa: E402

todas = cargar()
por_dominio = {}
for d in todas.values():
    por_dominio.setdefault(d.get("dominio") or "sin_dominio", []).append(d)

vig = sum(1 for d in todas.values() if d.get("estado") == "vigente")
sup = len(todas) - vig
# Sólo lo que está PENDIENTE de revisar: lo de `candidatos/archivo/` ya se miró
# y se cerró (promovido a una decisión o descartado con motivo). Contarlo todo
# hacía que el índice reportara 27 candidatos sin promover cuando no quedaba
# ninguno, que es la clase de número que hace ignorar el índice entero.
cands = len([f for f in (DECISIONES / "candidatos").rglob("*.md")
             if "archivo" not in f.parts and f.name != "README.md"]) \
        if (DECISIONES / "candidatos").is_dir() else 0

sal = ["# Índice de decisiones", "",
       "Generado por `bin/gen_indice_decisiones.py`. **No editar a mano.**", "",
       f"{len(todas)} decisiones ({vig} vigentes, {sup} superadas o descartadas) "
       f"· {cands} candidatos sin promover en `candidatos/`", ""]
for dom in sorted(por_dominio):
    sal += [f"## {dom}", "", "| id | estado | título | invariantes |", "|---|---|---|---|"]
    for d in sorted(por_dominio[dom], key=lambda x: x["id"]):
        marca = {"vigente": "✅", "superada": "⛔", "descartada": "⛔"}.get(d.get("estado"), "🟡")
        sal.append(f"| [`{d['id']}`]({Path(d['archivo']).name}) | {marca} {d.get('estado')} "
                   f"| {d.get('titulo','')} | {len(d.get('invariantes') or [])} |")
    sal.append("")
sal += ["---", "",
        "`candidatos/` no es normativo: es material extraído de migraciones, de la",
        "memoria de Claude y de los transcripts, pendiente de revisión humana.", ""]
(DECISIONES / "INDICE.md").write_text("\n".join(sal))
print(f"INDICE.md: {len(todas)} decisiones, {cands} candidatos")
