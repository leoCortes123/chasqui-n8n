#!/usr/bin/env python3
"""Rescata de los transcripts de Claude Code lo que dijo el usuario y no quedó escrito.

POR QUÉ EXISTE

Chasqui tiene 21 commits desde el 2026-08-14 y 38 sesiones de trabajo desde el
2026-07-22. Todo lo que se discutió, se corrigió y se descartó antes de agosto
existe únicamente en 40 MB de JSONL en
~/.claude/projects/-mnt-datos-Programacion-chasqui-n8n/. Esa es la mitad de las
decisiones del proyecto, fuera de git, en un formato propietario y atada a un
harness. Este script la saca de ahí una sola vez.

QUÉ RESCATA

Sólo turnos escritos por el usuario, nunca respuestas del modelo: lo que vale es
la instrucción y la corrección humana, no lo que un agente dedujo. De esos, los
que tienen forma de corregir un rumbo o de fijar una regla.

QUÉ NO HACE

No decide nada. Emite un informe con la cita textual, la fecha y la sesión de
origen, para revisión humana. Una corrección de julio puede haber quedado sin
efecto en agosto.

USO
    python3 bin/extraer_sesiones.py [--min-largo 40]
"""
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

SESIONES = Path.home() / ".claude" / "projects" / "-mnt-datos-Programacion-chasqui-n8n"
SALIDA = Path(__file__).resolve().parent.parent / "decisiones" / "candidatos" / "desde_sesiones.md"

# Formas de corregir un rumbo o de fijar una regla. Deliberadamente estrecho:
# más vale perder material que ahogar la revisión en ruido.
SENALES = [
    (re.compile(r"\b(no|nunca|jamás)\s+(se|debe|debes|hay que|quiero|uses|use|pongas|toques|borres|crees)\b", re.I), "prohibición"),
    (re.compile(r"\b(siempre|obligatori\w+|tiene que|debe ser|asegúrate|asegurate)\b", re.I), "regla"),
    (re.compile(r"\b(en realidad|no es así|estás? equivocad\w+|mal entendid\w+|te equivocaste|eso no|corrige|corregí)\b", re.I), "corrección"),
    (re.compile(r"\b(descart\w+|mejor no|no vale la pena|dejemos|olvid\w+ (eso|esa|ese)|no sigamos)\b", re.I), "descarte"),
    (re.compile(r"\b(la idea es|el objetivo es|lo que quiero es|el punto es|recuerda que|ten en cuenta)\b", re.I), "intención"),
    (re.compile(r"\b(prefiero|preferiría|me gusta más|mejor que)\b", re.I), "preferencia"),
]

# Ruido: órdenes operativas sin contenido normativo.
RUIDO = re.compile(
    r"^(continua|continúa|sigue|dale|ok|listo|gracias|perfecto|si|sí|no|ya|"
    r"prueba|corre|ejecuta|revisa)\b[\s.!]*$", re.I)


def texto_de(msg):
    c = msg.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(b.get("text", "") for b in c
                         if isinstance(b, dict) and b.get("type") == "text")
    return ""


def main():
    min_largo = 40
    if "--min-largo" in sys.argv:
        min_largo = int(sys.argv[sys.argv.index("--min-largo") + 1])

    if not SESIONES.is_dir():
        print(f"no existe {SESIONES}", file=sys.stderr)
        return 1

    por_fecha = defaultdict(list)
    sesiones = sorted(SESIONES.glob("*.jsonl"))
    for archivo in sesiones:
        for linea in archivo.read_text(errors="replace").splitlines():
            try:
                d = json.loads(linea)
            except Exception:
                continue
            if d.get("type") != "user":
                continue
            msg = d.get("message") or {}
            t = texto_de(msg).strip()
            # Los resultados de herramienta y los recordatorios del sistema
            # llegan con type=user pero no los escribió el usuario.
            if (not t or len(t) < min_largo or RUIDO.match(t)
                    or t.startswith("<") or "tool_result" in linea[:200]
                    or "system-reminder" in t or "Caveat:" in t[:80]):
                continue
            etiquetas = sorted({nombre for rx, nombre in SENALES if rx.search(t)})
            if not etiquetas:
                continue
            fecha = (d.get("timestamp") or "")[:10] or "sin-fecha"
            por_fecha[fecha].append((etiquetas, t, archivo.stem[:8]))

    total = sum(len(v) for v in por_fecha.values())
    sal = [
        "# Candidatos rescatados de las sesiones de trabajo",
        "",
        f"**Procedencia:** {len(sesiones)} transcripts en `{SESIONES}`, "
        "extraídos el 2026-08-18 con `bin/extraer_sesiones.py`.",
        "",
        "**No son decisiones.** Son turnos escritos por el usuario con forma de",
        "corrección, prohibición o regla. Están sin filtrar y sin verificar: una",
        "corrección de julio puede haber quedado sin efecto en agosto, y el",
        "detector no distingue una regla permanente de una instrucción puntual.",
        "",
        "Revisar de abajo hacia arriba (lo más reciente primero) y promover a",
        "`decisiones/` sólo lo que siga gobernando hoy.",
        "",
        f"{total} turnos en {len(por_fecha)} días.",
        "",
        "---",
        "",
    ]
    for fecha in sorted(por_fecha, reverse=True):
        sal += [f"## {fecha}", ""]
        for etiquetas, t, sid in por_fecha[fecha]:
            recorte = t if len(t) <= 700 else t[:700].rsplit(" ", 1)[0] + " […]"
            sal += [f"**[{', '.join(etiquetas)}]** · sesión `{sid}`", "",
                    "> " + recorte.replace("\n", "\n> "), ""]

    SALIDA.write_text("\n".join(sal))
    print(f"{total} turnos rescatados de {len(sesiones)} sesiones "
          f"({len(por_fecha)} días) -> {SALIDA.relative_to(SALIDA.parents[2])}")
    conteo = defaultdict(int)
    for v in por_fecha.values():
        for etiquetas, _, _ in v:
            for e in etiquetas:
                conteo[e] += 1
    print("por señal: " + ", ".join(f"{k} {v}" for k, v in sorted(conteo.items(), key=lambda kv: -kv[1])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
