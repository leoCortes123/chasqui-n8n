#!/usr/bin/env python3
"""Piezas compartidas por los tres scripts de datos de prueba.

Cero dependencias: solo stdlib, como el resto de `bin/`. Acá vive lo que los
tres necesitan y ninguno debería reimplementar — leer el .env, hablarle a psql
por docker, leer el .xlsx de UCI sin pandas, calcular un NIT con dígito de
verificación y normalizar salidas para poder comparar dos corridas.
"""
import datetime as dt
import json
import pathlib
import re
import subprocess
import sys
import unicodedata
import zipfile
import xml.etree.ElementTree as ET

RAIZ = pathlib.Path(__file__).resolve().parent.parent
GENERADOS = RAIZ / "ejemplos" / "generados"
MANIFIESTOS = GENERADOS / "manifests"
FUENTE = RAIZ / "ejemplos" / "fuente"

# El prefijo con el que se reconocen —y se borran— los negocios generados.
PREFIJO = "PRUEBA GEN "

URL_UCI = "https://archive.ics.uci.edu/dataset/502/online+retail+ii"


# ---------------------------------------------------------------------------
# Entorno y base
# ---------------------------------------------------------------------------
def env():
    """Las mismas variables que usan los scripts bash, sin dependencias."""
    valores = {}
    for linea in (RAIZ / ".env").read_text().splitlines():
        linea = linea.strip()
        if linea and not linea.startswith("#") and "=" in linea:
            k, _, v = linea.partition("=")
            valores[k.strip()] = v.strip().strip('"').strip("'")
    return valores


def psql(e, sql, entrada=None, tolerar=False):
    """psql dentro del contenedor, como bin/migrar.sh y gen_ventas_demo.py."""
    cmd = ["docker", "compose", "exec", "-T",
           "-e", f"PGPASSWORD={e['CHASQUI_DB_PASSWORD']}",
           "postgres", "psql", "-v", "ON_ERROR_STOP=1", "-qtA",
           "-U", e["CHASQUI_DB_USER"], "-d", e["CHASQUI_DB"]]
    cmd += ["-f", "-"] if entrada is not None else ["-c", sql]
    r = subprocess.run(cmd, cwd=RAIZ, input=entrada if entrada is not None else None,
                       capture_output=True, text=True)
    if r.returncode != 0:
        if tolerar:
            return None
        sys.exit(f"psql falló:\n{r.stderr.strip()}\n--- SQL ---\n{(entrada or sql)[:2000]}")
    return r.stdout.strip()


def psql_json(e, sql):
    salida = psql(e, sql)
    return json.loads(salida) if salida else None


# ---------------------------------------------------------------------------
# Identidades colombianas sintéticas
# ---------------------------------------------------------------------------
_PESOS_DV = [3, 7, 13, 17, 19, 23, 29, 37, 41, 43, 47, 53, 59, 67, 71]


def nit_dv(nit: str) -> int:
    """El mismo cálculo que `nit_dv()` en la base (DIAN, resolución 8-1998)."""
    digitos = [int(c) for c in re.sub(r"\D", "", nit)]
    s = sum(d * _PESOS_DV[i] for i, d in enumerate(reversed(digitos)))
    r = s % 11
    return 0 if r in (0, 1) else 11 - r


def nit_con_dv(base: int) -> str:
    """`900123456-7`: NIT sintético de persona jurídica con su verificador."""
    n = str(base)
    return f"{n}-{nit_dv(n)}"


def slug(texto: str) -> str:
    t = unicodedata.normalize("NFKD", texto).encode("ascii", "ignore").decode()
    return re.sub(r"[^a-z0-9]+", "_", t.lower()).strip("_")


# ---------------------------------------------------------------------------
# Normalización de salida (la técnica de _norm() en db/pruebas/router_casos.sql)
# ---------------------------------------------------------------------------
_RE_ID = re.compile(r"\b\d{4,}\b")
_RE_FECHA = re.compile(r"\b\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}:\d{2}[.\d]*(?:[+-]\d{2}:?\d{2})?)?")
_RE_OBJ = re.compile(r"\b(producto|tercero):\d+")


def norm(texto: str) -> str:
    """Enmascara ids de secuencia y fechas para comparar dos corridas.

    Los ids son IDENTITY y los timestamps son del reloj: dos corridas de la
    misma seed producen los mismos DATOS y distintos NÚMEROS de fila. Lo que
    tiene que coincidir es lo de la izquierda.
    """
    t = _RE_OBJ.sub(lambda m: m.group(1) + ":<id>", texto)
    t = _RE_FECHA.sub("<fecha>", t)
    return _RE_ID.sub("<n>", t)


# ---------------------------------------------------------------------------
# UCI Online Retail II — lectura sin pandas ni openpyxl
# ---------------------------------------------------------------------------
COLUMNAS_UCI = ["InvoiceNo", "StockCode", "Description", "Quantity",
                "InvoiceDate", "UnitPrice", "CustomerID", "Country"]

_EPOCA_EXCEL = dt.datetime(1899, 12, 30)
_NS_SS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"


def _shared_strings(z):
    """sharedStrings.xml -> lista. Es medio mega: se lee entero y se descarta."""
    if "xl/sharedStrings.xml" not in z.namelist():
        return []
    fuera = []
    with z.open("xl/sharedStrings.xml") as f:
        for ev, el in ET.iterparse(f, events=("end",)):
            if el.tag == _NS_SS + "si":
                fuera.append("".join(t.text or "" for t in el.iter(_NS_SS + "t")))
                el.clear()
    return fuera


def _celda_col(ref):
    return re.sub(r"\d", "", ref or "")


def leer_xlsx(ruta: pathlib.Path):
    """Streamea las dos hojas del .xlsx de UCI como dicts con COLUMNAS_UCI.

    Las fechas vienen como serial de Excel (numFmt 22) y los textos como
    índices a sharedStrings: los dos casos se resuelven acá y afuera solo se
    ven valores de Python.
    """
    z = zipfile.ZipFile(ruta)
    ss = _shared_strings(z)
    hojas = sorted(n for n in z.namelist()
                   if re.fullmatch(r"xl/worksheets/sheet\d+\.xml", n))
    letras = [chr(ord("A") + i) for i in range(len(COLUMNAS_UCI))]

    for hoja in hojas:
        with z.open(hoja) as f:
            primera = True
            fila = {}
            for ev, el in ET.iterparse(f, events=("end",)):
                if el.tag == _NS_SS + "c":
                    v = el.find(_NS_SS + "v")
                    if v is not None and v.text is not None:
                        val = ss[int(v.text)] if el.get("t") == "s" else v.text
                        fila[_celda_col(el.get("r"))] = val
                    el.clear()
                elif el.tag == _NS_SS + "row":
                    if primera:
                        primera = False          # cabecera
                    elif fila:
                        yield _fila_uci(fila, letras)
                    fila = {}
                    el.clear()


def _fila_uci(celdas, letras):
    d = {c: celdas.get(l) for c, l in zip(COLUMNAS_UCI, letras)}
    serial = d.get("InvoiceDate")
    if serial is not None:
        try:
            d["InvoiceDate"] = _EPOCA_EXCEL + dt.timedelta(days=float(serial))
        except ValueError:
            d["InvoiceDate"] = None
    return d


def cache_csv(ruta_entrada: pathlib.Path) -> pathlib.Path:
    """El .xlsx tarda minutos en parsearse; el cache lo deja en segundos.

    Se guarda al lado del original, ya limpio de columnas que no usamos y con
    la fecha en ISO. No se versiona (todo `fuente/` está en .gitignore).
    """
    return ruta_entrada.with_suffix(".limpio.csv")


def escribir_cache(ruta_entrada: pathlib.Path, destino: pathlib.Path):
    import csv
    with destino.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["factura", "codigo", "descripcion", "cantidad",
                    "fecha", "precio", "cliente", "pais"])
        n = 0
        for r in leer_xlsx(ruta_entrada):
            if r["InvoiceDate"] is None:
                continue
            w.writerow([r["InvoiceNo"], r["StockCode"], r["Description"] or "",
                        r["Quantity"], r["InvoiceDate"].isoformat(sep=" "),
                        r["UnitPrice"], r["CustomerID"] or "", r["Country"] or ""])
            n += 1
        return n


def leer_fuente(ruta: pathlib.Path):
    """Devuelve un iterador de filas UCI normalizadas, desde .xlsx o .csv.

    Con .xlsx se construye —una sola vez— un cache CSV al lado del archivo.
    """
    import csv
    if not ruta.exists():
        sys.exit(
            f"no encuentro {ruta}.\n"
            f"Bajá el dataset de {URL_UCI} y dejá online_retail_II.xlsx en "
            f"{FUENTE.relative_to(RAIZ)}/ (no se versiona: pesa 45 MB).")

    if ruta.suffix.lower() == ".xlsx":
        cache = cache_csv(ruta)
        if not cache.exists() or cache.stat().st_mtime < ruta.stat().st_mtime:
            print(f"  primera lectura de {ruta.name}: armando cache…", flush=True)
            n = escribir_cache(ruta, cache)
            print(f"  cache {cache.name}: {n:,} filas".replace(",", "."), flush=True)
        ruta = cache

    with ruta.open(newline="") as f:
        for r in csv.DictReader(f):
            yield r
