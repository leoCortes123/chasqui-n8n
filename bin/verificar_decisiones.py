#!/usr/bin/env python3
"""Chequeos estructurales de decisiones/. Imprime una violación por línea."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from mcp_decisiones import cargar, DECISIONES, RAIZ  # noqa: E402

todas = cargar()
malas = []
ESTADOS = {"vigente", "superada", "descartada"}

for d in todas.values():
    n = d["id"]
    if d.get("estado") not in ESTADOS:
        malas.append(f"{n}: estado '{d.get('estado')}' no es vigente/superada/descartada")
    if d.get("estado") == "superada" and not d.get("motivo_reemplazo"):
        malas.append(f"{n}: superada sin motivo_reemplazo")
    if d.get("estado") == "superada" and not d.get("superseded_by"):
        malas.append(f"{n}: superada sin superseded_by")
    if d.get("estado") == "vigente" and d.get("superseded_by"):
        malas.append(f"{n}: vigente pero declara superseded_by={d['superseded_by']}")
    for campo in ("supersede", "relacionada_con"):
        for ref in (d.get(campo) or []):
            if ref not in todas:
                malas.append(f"{n}: {campo} apunta a {ref}, que no existe")
    sb = d.get("superseded_by")
    if sb and sb not in todas:
        malas.append(f"{n}: superseded_by apunta a {sb}, que no existe")
    if sb and n not in (todas.get(sb, {}).get("supersede") or []):
        malas.append(f"{n}: dice superseded_by={sb} pero {sb} no lo lista en supersede")
    if not d.get("invariantes") and d.get("estado") == "vigente":
        malas.append(f"{n}: vigente sin ningún invariante declarado")
    if not d.get("procedencia"):
        malas.append(f"{n}: sin procedencia")
    # afecta: nombres de función o rutas; se acepta cualquiera que resuelva
    for ruta in (d.get("afecta") or []):
        if "/" in ruta:
            existe = (RAIZ / ruta).exists()
        else:
            existe = bool(list((RAIZ / "db/actual").rglob(f"{ruta}*.sql"))) or \
                     bool(list((RAIZ / "bin").glob(f"*{ruta}*")))
        if not existe:
            malas.append(f"{n}: afecta a '{ruta}', que no existe en db/actual/ ni bin/")
    for ruta in (d.get("implementada_en") or []):
        if "/" in ruta and not (RAIZ / ruta).exists():
            malas.append(f"{n}: implementada_en '{ruta}', que no existe")

# ciclos de supersede
for n in todas:
    visto, actual = set(), n
    while actual and actual in todas:
        if actual in visto:
            malas.append(f"{n}: ciclo en la cadena de supersede")
            break
        visto.add(actual)
        actual = todas[actual].get("superseded_by")

# invariantes en conflicto: dos vigentes del mismo dominio con el mismo texto
por_dom = {}
for d in todas.values():
    if d.get("estado") == "vigente":
        for i in (d.get("invariantes") or []):
            clave = (d.get("dominio"), i.strip().lower())
            if clave in por_dom:
                malas.append(f"{d['id']} y {por_dom[clave]}: invariante duplicado en el dominio "
                             f"'{d.get('dominio')}' — uno debería superseder al otro")
            por_dom[clave] = d["id"]

# índice al día
indice = DECISIONES / "INDICE.md"
if not indice.exists():
    malas.append("falta decisiones/INDICE.md: correr bin/gen_indice_decisiones.py")
else:
    texto = indice.read_text()
    for n in todas:
        if n not in texto:
            malas.append(f"INDICE.md no lista {n}: correr bin/gen_indice_decisiones.py")

print("\n".join(malas))
sys.exit(1 if malas else 0)
