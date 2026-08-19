#!/usr/bin/env python3
"""Extrae candidatos a decisión desde las cabeceras de db/migraciones/.

POR QUÉ EXISTE

El porqué de cada cambio de Chasqui ya está escrito: 73 migraciones con
cabeceras en prosa que traen el problema medido, las reglas que salen de ahí y
lo que se descartó. Lo que no está es en forma consultable — sin id, sin estado,
sin dominio, sin relaciones. Este script hace la parte mecánica de esa
conversión.

LO QUE ESTE SCRIPT NO HACE

No produce decisiones. Produce **candidatos**. Una cabecera puede contener un
razonamiento que era correcto en su momento y que una migración posterior dejó
sin efecto — 45 funciones están redefinidas al menos una vez, así que eso pasa
seguido. Decidir cuál sigue vigente, cuál quedó superada y por cuál, es criterio
de producto y lo hace un humano.

Por eso todo sale a decisiones/candidatos/ con estado: candidato y con su
procedencia intacta.

USO
    python3 bin/gen_candidatos.py            escribe decisiones/candidatos/
    python3 bin/gen_candidatos.py --dry-run  sólo informa
"""
import re
import subprocess
import sys
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
MIGRACIONES = RAIZ / "db" / "migraciones"
DESTINO = RAIZ / "decisiones" / "candidatos"

# El dominio se infiere del prefijo de los objetos que toca la migración, no de
# su nombre de archivo: el nombre describe el cambio, los objetos describen
# dónde cae. Se revisa a mano de todos modos.
DOMINIOS = {
    "router": "router", "teclado": "router", "intencion": "router",
    "chat": "router", "canal": "router", "wa": "router",
    "ingesta": "ingesta", "carga": "ingesta", "match": "ingesta",
    "alias": "ingesta", "formato": "ingesta", "documento": "ingesta",
    "hallazgos": "hallazgos", "recomendacion": "hallazgos",
    "recomendaciones": "hallazgos", "salud": "hallazgos",
    "informe": "informe", "plantilla": "informe", "prompt": "informe",
    "validar": "informe", "cifra": "informe",
    "alerta": "alertas", "alertas": "alertas", "mantenimiento": "alertas",
    "cron": "alertas", "notif": "alertas",
    "portal": "portal", "jwt": "portal", "usuario": "portal",
    "ejecucion": "ejecucion", "pedido": "ejecucion", "metricas": "ejecucion",
    "snapshot": "cerebro", "snapshots": "cerebro", "perfil": "cerebro",
    "conocimiento": "cerebro", "consulta": "cerebro",
    "cartera": "cartera", "factura": "cartera", "pago": "cartera",
    "plan": "planes", "consentimiento": "planes",
    "movimientos": "datos", "producto": "datos", "tercero": "datos",
    "inventario": "datos", "conteo": "datos", "periodo": "datos",
    "servicio": "servicios", "servicios": "servicios", "modulo": "servicios",
    "menu": "servicios", "menus": "servicios",
}

# Señales de que un párrafo enuncia una regla y no describe una implementación.
SENAL_REGLA = re.compile(
    r"\b(nunca|jamás|siempre|no puede|no debe|prohibid|reglas?|invariante|"
    r"debe ser|tiene que|obligatori|qué queda|cómo queda)\w*\b", re.I)
SENAL_DESCARTE = re.compile(
    r"\b(descartad|se descartó|alternativa|en vez de|no se hizo|"
    r"por qué no|por qué se|se evaluó|rechazad)\w*\b", re.I)


def cabecera(texto):
    """Las líneas de comentario iniciales, sin los guiones."""
    lineas = []
    for linea in texto.splitlines():
        if linea.startswith("--"):
            lineas.append(linea[2:].strip())
        elif linea.strip() == "":
            if lineas:
                lineas.append("")
        else:
            break
    while lineas and lineas[-1] == "":
        lineas.pop()
    return "\n".join(lineas)


def objetos(texto):
    return sorted(set(re.findall(
        r"CREATE (?:OR REPLACE )?(?:FUNCTION|VIEW|TABLE)\s+(?:public\.)?([a-z0-9_]+)",
        texto, re.I)))


def dominio(objs, nombre_archivo):
    votos = {}
    for o in objs + [nombre_archivo]:
        for parte in o.split("_"):
            if parte in DOMINIOS:
                votos[DOMINIOS[parte]] = votos.get(DOMINIOS[parte], 0) + 1
    if not votos:
        return "sin_clasificar"
    return max(votos.items(), key=lambda kv: (kv[1], kv[0]))[0]


def commit_de(ruta):
    try:
        r = subprocess.run(
            ["git", "log", "-1", "--format=%h %ad", "--date=short", "--", str(ruta)],
            cwd=RAIZ, capture_output=True, text=True, timeout=15)
        return r.stdout.strip() or "sin commit (migración aún no versionada)"
    except Exception:
        return "sin commit"


# Las cabeceras de este repo usan títulos en mayúsculas para separar secciones
# ("EL PROBLEMA, MEDIDO EN LA SEGUNDA PRUEBA DE USUARIO", "LAS TRES REGLAS QUE
# SALEN DE AHÍ", "POR QUÉ SE CALCULA AL RENDERIZAR Y NO EN hallazgos_generar").
# Trocear por ahí da secciones reales; buscar frases sueltas devolvía narrativa.
TITULO = re.compile(r"^[A-ZÁÉÍÓÚÑ0-9][A-ZÁÉÍÓÚÑ0-9 ,.:;()\-'\"]{9,}$")


def secciones(cab):
    """{título: cuerpo} troceando por las líneas-título en mayúsculas."""
    actual, bloques = None, {}
    for linea in cab.splitlines():
        l = linea.strip()
        if TITULO.match(l) and not l.endswith(","):
            actual = l
            bloques[actual] = []
        elif actual is not None:
            bloques[actual].append(linea)
    return {k: "\n".join(v).strip() for k, v in bloques.items() if "".join(v).strip()}


def frases(cab):
    """Secciones que enuncian reglas, y secciones que explican un descarte."""
    reglas, descartes = [], []
    for titulo, cuerpo in secciones(cab).items():
        if SENAL_DESCARTE.search(titulo) or SENAL_DESCARTE.search(cuerpo[:400]):
            descartes.append((titulo, cuerpo))
        elif SENAL_REGLA.search(titulo) or SENAL_REGLA.search(cuerpo[:400]):
            reglas.append((titulo, cuerpo))
    return reglas[:4], descartes[:3]


def main():
    seco = "--dry-run" in sys.argv
    if not seco:
        DESTINO.mkdir(parents=True, exist_ok=True)

    resumen, sin_cabecera = [], []
    for f in sorted(MIGRACIONES.glob("[0-9][0-9][0-9]_*.sql")):
        texto = f.read_text()
        cab = cabecera(texto)
        num = f.name[:3]
        slug = f.stem[4:]
        objs = objetos(texto)
        dom = dominio(objs, slug)
        reglas, descartes = frases(cab)

        if len(cab.splitlines()) < 5:
            sin_cabecera.append(f.name)

        titulo = (cab.splitlines() or [slug.replace("_", " ")])[0].strip(" .-")
        resumen.append((num, dom, len(reglas), len(descartes), titulo[:60]))

        if seco:
            continue

        cuerpo = [
            "---",
            f"id: CAND-{num}",
            f"dominio: {dom}",
            "estado: candidato",
            "titulo: " + titulo.replace(":", " -")[:100],
            "invariantes: []          # llenar a mano al promover",
            "supersede: []",
            "superseded_by: null",
            "motivo_reemplazo: null",
            "relacionada_con: []",
            f"implementada_en: [db/migraciones/{f.name}]",
            "afecta:",
        ]
        for o in objs:
            ruta = RAIZ / "db" / "actual" / "funciones" / f"{o}.sql"
            marca = "" if ruta.exists() else "   # ya no existe en db/actual/"
            cuerpo.append(f"  - {o}{marca}")
        if not objs:
            cuerpo.append("  []")
        cuerpo += [
            f"procedencia: cabecera de db/migraciones/{f.name}, commit {commit_de(f)}",
            "---",
            "",
            "> **Candidato, no decisión.** Extraído automáticamente el 2026-08-18.",
            "> Nada de acá gobierna hasta que se revise, se le fije estado y se",
            "> mueva a `decisiones/`.",
            "",
        ]
        if reglas:
            cuerpo += ["## Reglas enunciadas en la cabecera", ""]
            for titulo, texto_sec in reglas:
                cuerpo += [f"### {titulo}", "", texto_sec, ""]
        if descartes:
            cuerpo += ["## Alternativas mencionadas como descartadas", ""]
            for titulo, texto_sec in descartes:
                cuerpo += [f"### {titulo}", "", texto_sec, ""]
        cuerpo += ["## Cabecera completa, textual", "", "```", cab, "```", ""]
        (DESTINO / f"CAND-{num}-{dom}.md").write_text("\n".join(cuerpo))

    print(f"{len(resumen)} candidatos" + (" (dry-run)" if seco else f" en {DESTINO.relative_to(RAIZ)}/"))
    porc = {}
    for _, dom, _, _, _ in resumen:
        porc[dom] = porc.get(dom, 0) + 1
    print("\npor dominio: " + ", ".join(f"{d} {n}" for d, n in sorted(porc.items(), key=lambda kv: -kv[1])))
    con_reglas = sum(1 for r in resumen if r[2])
    con_desc   = sum(1 for r in resumen if r[3])
    print(f"con reglas detectadas: {con_reglas}/{len(resumen)}   "
          f"con descartes: {con_desc}/{len(resumen)}")
    if sin_cabecera:
        print(f"\nsin cabecera aprovechable ({len(sin_cabecera)}): {', '.join(sin_cabecera)}")


if __name__ == "__main__":
    main()
