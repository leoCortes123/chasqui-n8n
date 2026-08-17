#!/usr/bin/env python3
"""Valida el dataset generado y calcula el oráculo independiente.

Dos trabajos en un solo paso, porque comparten la misma lectura de los archivos:

  1. VALIDACIÓN (§14 del plan): que los archivos sean coherentes entre sí antes
     de tocar Chasqui — cantidades y precios positivos, compras que sostienen
     las ventas, XML que cuadran, fechas dentro del período, ningún negocio
     nombrando productos o proveedores de otro, ningún documento por encima de
     la compuerta de calidad salvo el diseñado para probarla.

  2. ORÁCULO: qué reglas DEBERÍAN dispararse, calculado en Python desde los
     archivos, implementando cada umbral desde su definición. No se traduce el
     SQL de Chasqui: si el oráculo repitiera la misma consulta, un mismo error
     pasaría las dos pruebas y no probaríamos nada.

Escribe `docs/ejemplos/generados/manifests/oracle.json` y devuelve código 1 si
algo falla.

    python3 bin/validar_datos_prueba.py
    python3 bin/validar_datos_prueba.py --sin-base   # sin comparar parámetros
"""
import argparse
import collections
import csv
import datetime as dt
import json
import hashlib
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from datos_prueba_comun import (  # noqa: E402
    MANIFIESTOS, RAIZ, env, nit_dv, norm, psql, slug)
from gen_datos_prueba import UMBRALES  # noqa: E402

U = UMBRALES


# ---------------------------------------------------------------------------
# Lectura de los archivos generados
# ---------------------------------------------------------------------------
def leer_ventas(ruta):
    with ruta.open(newline="") as f:
        for r in csv.DictReader(f):
            yield r


def leer_compra(ruta):
    """Lee la factura UBL, desenvolviendo el AttachedDocument si hace falta."""
    texto = ruta.read_text()
    m = re.search(r"<!\[CDATA\[(.*?)\]\]>", texto, re.S)
    if m:
        texto = m.group(1)
    raiz = ET.fromstring(texto)

    def uno(nodo, local):
        for e in nodo.iter():
            if e.tag.rsplit("}", 1)[-1] == local:
                return e
        return None

    def texto_de(nodo, local):
        e = uno(nodo, local)
        return e.text if e is not None else None

    proveedor = None
    nit_prov = None
    for e in raiz.iter():
        if e.tag.rsplit("}", 1)[-1] == "AccountingSupplierParty":
            proveedor = texto_de(e, "RegistrationName")
            nit_prov = texto_de(e, "CompanyID")
            break
    cabecera = {
        "numero": texto_de(raiz, "ID"),
        "fecha": dt.date.fromisoformat(texto_de(raiz, "IssueDate")),
        "proveedor": proveedor, "nit_proveedor": nit_prov,
        "impuesto": float(texto_de(uno(raiz, "TaxTotal"), "TaxAmount")),
        "pagar": float(texto_de(uno(raiz, "LegalMonetaryTotal"), "PayableAmount")),
    }
    lineas = []
    for e in raiz.iter():
        if e.tag.rsplit("}", 1)[-1] != "InvoiceLine":
            continue
        lineas.append({
            "producto": texto_de(uno(e, "Item"), "Description"),
            "codigo": texto_de(uno(e, "StandardItemIdentification"), "ID"),
            "cantidad": float(texto_de(e, "InvoicedQuantity")),
            "total": float(texto_de(e, "LineExtensionAmount")),
            "precio": float(texto_de(uno(e, "Price"), "PriceAmount")),
        })
    return cabecera, lineas


def cargar_escenario(base, esc):
    """Reconstruye el negocio entero: ventas, compras, conteos y cartera."""
    carpeta = base / slug(esc["escenario"])
    ventas, compras, rechazables = [], [], []
    for mes in esc["carga"]["meses"]:
        for nombre in mes["ventas"]:
            for r in leer_ventas(carpeta / nombre):
                ventas.append({"archivo": nombre, "mes": mes["mes"], **r})
        for nombre in mes["compras"]:
            cab, lineas = leer_compra(carpeta / nombre)
            compras.append({"archivo": nombre, "mes": mes["mes"],
                            "cabecera": cab, "lineas": lineas})
        for nombre in mes.get("rechazables", []):
            rechazables.append((nombre, list(leer_ventas(carpeta / nombre))))
    conteos = [c for mes in esc["carga"]["meses"] for c in mes["conteos"]]
    facturas = [f for mes in esc["carga"]["meses"] for f in mes["facturas"]]
    pagos = [p for mes in esc["carga"]["meses"] for p in mes["pagos"]]
    return {"ventas": ventas, "compras": compras, "rechazables": rechazables,
            "conteos": conteos, "facturas": facturas, "pagos": pagos,
            "carpeta": carpeta}


# ---------------------------------------------------------------------------
# El oráculo
# ---------------------------------------------------------------------------
def oraculo(esc, datos):
    """Qué reglas deben dispararse, desde la DEFINICIÓN de cada umbral.

    Nada de esto traduce una consulta de Chasqui: son las once definiciones,
    escritas otra vez y en otro lenguaje, sobre los archivos generados.
    """
    catalogo = {l["producto"] for c in datos["compras"] for l in c["lineas"]}

    v_por_prod = collections.defaultdict(list)   # nombre -> [(fecha, cant, precio)]
    for r in datos["ventas"]:
        nombre = r["producto"]
        f = dt.date.fromisoformat(r["fecha"])
        v_por_prod[nombre].append((f, float(r["cantidad"]),
                                   float(r["precio_unitario"])))

    c_por_prod = collections.defaultdict(list)   # nombre -> [(fecha, cant, precio, prov)]
    gasto_prov = collections.Counter()
    for c in datos["compras"]:
        prov = c["cabecera"]["proveedor"]
        f = c["cabecera"]["fecha"]
        for l in c["lineas"]:
            c_por_prod[l["producto"]].append((f, l["cantidad"], l["precio"], prov))
            gasto_prov[prov] += l["total"]

    for lista in list(v_por_prod.values()) + list(c_por_prod.values()):
        lista.sort(key=lambda x: x[0])

    fechas = [f for v in v_por_prod.values() for f, *_ in v] + \
             [f for c in c_por_prod.values() for f, *_ in c]
    hasta = max(fechas)
    desde = min(fechas)
    hoy = dt.date.today()

    conteo_de = {}
    for c in datos["conteos"]:
        fecha = (dt.date.fromisoformat(c["fecha"]) if c.get("fecha") else hoy)
        # El último conteo de cada producto es el que manda.
        previo = conteo_de.get(c["producto"])
        if previo is None or fecha >= previo[0]:
            conteo_de[c["producto"]] = (fecha, float(c["unidades"]),
                                        bool(c.get("despues_de_registrar")))

    reglas = collections.defaultdict(list)
    detalle = {}

    for nombre in sorted(catalogo):
        ven = v_por_prod.get(nombre, [])
        com = c_por_prod.get(nombre, [])
        d = {}

        # --- costo: cuánto subió el costo de punta a punta -------------------
        if len(com) >= 2:
            ini, fin = com[0][2], com[-1][2]
            d["deriva_pct"] = (fin - ini) / ini * 100 if ini else 0
            if d["deriva_pct"] >= U["deriva_costo_alerta_pct"]:
                reglas["costo"].append(nombre)

        # --- proveedor: hay dónde comprarlo más barato -----------------------
        por_prov = collections.defaultdict(lambda: [0.0, 0.0])
        for f, cant, precio, prov in com:
            por_prov[prov][0] += cant
            por_prov[prov][1] += cant * precio
        if len(por_prov) > 1:
            medias = {p: v[1] / v[0] for p, v in por_prov.items() if v[0]}
            u_total = sum(v[0] for v in por_prov.values())
            pagado = sum(v[1] for v in por_prov.values()) / u_total
            mejor = min(medias.values())
            d["precio_pagado"], d["precio_mejor"] = pagado, mejor
            if pagado > mejor * 1.05:
                reglas["proveedor"].append(nombre)

        # --- margen: el de la punta de la serie, no el promedio --------------
        if ven and com:
            precio = ven[-1][2]
            costo = com[-1][2]
            d["margen_pct"] = (precio - costo) / precio * 100 if precio else None
            if d["margen_pct"] is not None and d["margen_pct"] < U["margen_minimo_pct"]:
                reglas["margen"].append(nombre)

        # --- balance y cobertura --------------------------------------------
        if ven:
            ventana = max((ven[-1][0] - ven[0][0]).days, 1)
            unidades = sum(c for _, c, _ in ven)
            por_dia = unidades / ventana
            if nombre in conteo_de:
                fconteo, uconteo, _ = conteo_de[nombre]
                balance = (uconteo
                           + sum(c for f, c, _, _ in com if f > fconteo)
                           - sum(c for f, c, _ in ven if f > fconteo))
                origen = "conteo" if not any(
                    f > fconteo for f, *_ in list(com) + list(ven)) else "calculado"
            else:
                balance = sum(c for _, c, _, _ in com) - unidades
                origen = "estimado"
            cobertura = balance / por_dia if por_dia else None
            d.update(balance=balance, dias_cobertura=cobertura,
                     origen_stock=origen, unidades_por_dia=por_dia)
            if cobertura is not None and por_dia > 0:
                if cobertura < U["dias_cobertura_min"]:
                    reglas["agota"].append(nombre)
                if cobertura > U["rotacion_lenta_dias"] and balance > 0:
                    reglas["quieto"].append(nombre)

            # --- sin_ventas ---------------------------------------------------
            dias = (hasta - ven[-1][0]).days
            d["dias_sin_vender"] = dias
            if (dias > U["dias_sin_venta_alerta"]
                    and len(ven) >= U["ventas_minimas_historicas"]
                    and (ven[-1][0] - ven[0][0]).days >= 14):
                reglas["sin_ventas"].append(nombre)

        # --- proveedor_sube: subidas seguidas del MISMO proveedor -------------
        for prov in por_prov:
            serie = [(f, p) for f, _, p, pr in com
                     if pr == prov and (hasta - f).days <= 365]
            subidas = sum(1 for k in range(1, len(serie))
                          if serie[k][1] > serie[k - 1][1] * 1.01)
            if (subidas >= U["subidas_proveedor_alerta"] and len(serie) >= 2
                    and serie[-1][1] > serie[0][1]):
                reglas["proveedor_sube"].append(nombre)
                d["subidas"] = subidas
                break

        # --- margen_cae: el margen medido al cierre de cada mes ---------------
        cortes = [dt.date.fromisoformat(m["hasta"])
                  for m in esc["carga"]["meses"]]
        serie_margen = []
        for corte in cortes:
            cs = [p for f, _, p, _ in com if f <= corte]
            ps = [p for f, _, p in ven if f <= corte]
            if cs and ps and ps[-1]:
                serie_margen.append((ps[-1] - cs[-1]) / ps[-1] * 100)
        if len(serie_margen) >= 3:
            h0, h1, h2 = serie_margen[-1], serie_margen[-2], serie_margen[-3]
            d["margen_serie"] = [round(x, 2) for x in (h2, h1, h0)]
            if h0 < h1 < h2 and (h2 - h0) >= U["caida_margen_pp_alerta"]:
                reglas["margen_cae"].append(nombre)

        if d:
            detalle[nombre] = {k: (round(v, 3) if isinstance(v, float) else v)
                               for k, v in d.items()}

    # --- dependencia: un proveedor concentra el gasto -----------------------
    total = sum(gasto_prov.values())
    concentracion = {p: g * 100.0 / total for p, g in gasto_prov.items()} if total else {}
    for prov, pct in concentracion.items():
        if pct >= U["dependencia_proveedor_pct"]:
            reglas["dependencia"].append(prov)

    # --- vs_ano_anterior: el último mes COMPLETO contra el mismo del año pasado
    mes_ref = (hasta.year, hasta.month)
    if hasta != _fin_mes(*mes_ref):
        mes_ref = _mes_menos(mes_ref, 1)
    ant = _mes_menos(mes_ref, 12)
    ventas_mes = collections.Counter()
    for r in datos["ventas"]:
        f = dt.date.fromisoformat(r["fecha"])
        ventas_mes[(f.year, f.month)] += float(r["total"])
    ahora, antes = ventas_mes[mes_ref], ventas_mes[ant]
    caida = (antes - ahora) * 100.0 / antes if antes else 0
    if antes > 0 and caida >= U["caida_anual_pct_alerta"]:
        reglas["vs_ano_anterior"].append("negocio")

    # --- cartera: lo que te deben y ya se pasó de fecha ---------------------
    pagado_de = collections.Counter()
    for p in datos["pagos"]:
        pagado_de[p["numero"]] += p["valor"]
    vencido = 0.0
    por_tercero = collections.defaultdict(lambda: [0.0, 0])
    for f in datos["facturas"]:
        saldo = f["total"] - pagado_de[f["numero"]]
        venc = dt.date.fromisoformat(f["vencimiento"])
        if saldo > 0 and venc < hoy:
            vencido += saldo
            t = por_tercero[f["tercero"]]
            t[0] += saldo
            t[1] = max(t[1], (hoy - venc).days)
    mora = max((v[1] for v in por_tercero.values()), default=0)
    for tercero, (saldo, dias) in por_tercero.items():
        if saldo > 0 and dias >= U["cartera_mora_dias"]:
            reglas["cartera"].append(tercero)

    # --- el conteo que contradice la estimación -----------------------------
    # §8 del plan: el oráculo tiene que declarar cómo cambia la recomendación
    # antes y después del conteo. Se calcula la cobertura del producto con la
    # estimación (comprado − vendido) y con el conteo, y se dice qué regla
    # corresponde a cada una.
    contradice = []
    for nombre, (fconteo, uconteo, despues) in conteo_de.items():
        if not despues:
            continue
        ven = v_por_prod.get(nombre, [])
        com = c_por_prod.get(nombre, [])
        if not ven:
            continue
        ventana = max((ven[-1][0] - ven[0][0]).days, 1)
        por_dia = sum(c for _, c, _ in ven) / ventana

        def regla_de(balance):
            if not por_dia:
                return None, None
            cob = balance / por_dia
            if cob < U["dias_cobertura_min"]:
                return "agota", cob
            if cob > U["rotacion_lenta_dias"] and balance > 0:
                return "quieto", cob
            return None, cob

        est = sum(c for _, c, _, _ in com) - sum(c for _, c, _ in ven)
        r_antes, cob_antes = regla_de(est)
        r_desp, cob_desp = regla_de(
            uconteo + sum(c for f, c, _, _ in com if f > fconteo)
                    - sum(c for f, c, _ in ven if f > fconteo))
        contradice.append({
            "producto": nombre, "conteo_unidades": uconteo,
            "antes": {"origen_stock": "estimado", "balance": est,
                      "dias_cobertura": round(cob_antes or 0, 1),
                      "regla": r_antes},
            "despues": {"origen_stock": "conteo", "balance": uconteo,
                        "dias_cobertura": round(cob_desp or 0, 1),
                        "regla": r_desp}})

    return {
        "escenario": esc["escenario"],
        "negocio": esc["negocio"],
        "periodo": {"desde": desde.isoformat(), "hasta": hasta.isoformat()},
        "reglas": {k: sorted(v) for k, v in sorted(reglas.items())},
        "concentracion_proveedor_pct": {p: round(v, 1)
                                        for p, v in sorted(concentracion.items())},
        "vs_ano_anterior": {"mes_ref": f"{mes_ref[0]}-{mes_ref[1]:02d}",
                            "ahora": round(ahora), "antes": round(antes),
                            "caida_pct": round(caida, 1)},
        "cartera": {"saldo_vencido": round(vencido), "dias_mora": mora},
        "conteo_contradice": contradice,
        "productos": detalle,
    }


def _fin_mes(a, m):
    import calendar
    return dt.date(a, m, calendar.monthrange(a, m)[1])


def _mes_menos(par, k):
    t = par[0] * 12 + par[1] - 1 - k
    return t // 12, t % 12 + 1


# ---------------------------------------------------------------------------
# Validaciones
# ---------------------------------------------------------------------------
class Reporte:
    def __init__(self):
        self.filas = []

    def chk(self, prueba, ok, detalle=""):
        self.filas.append((prueba, bool(ok), detalle))

    def imprimir(self):
        ancho = max(len(f[0]) for f in self.filas)
        for prueba, ok, detalle in self.filas:
            print(f"  [{'PASS' if ok else 'FAIL'}] {prueba:<{ancho}}  {detalle}")
        fallaron = sum(1 for _, ok, _ in self.filas if not ok)
        print(f"\n{len(self.filas) - fallaron} pasaron, {fallaron} fallaron, "
              f"{len(self.filas)} total")
        return fallaron


def validar(esc, datos, orc, rep, catalogos, proveedores_globales):
    n = esc["escenario"]
    desde = dt.date.fromisoformat(esc["periodo"]["desde"])
    hasta = dt.date.fromisoformat(esc["periodo"]["hasta"])

    # 2. cantidades, precios y costos positivos y coherentes
    malas = [r for r in datos["ventas"]
             if float(r["cantidad"]) <= 0 or float(r["precio_unitario"]) <= 0
             or abs(float(r["total"]) - float(r["cantidad"])
                    * float(r["precio_unitario"])) > 1]
    rep.chk(f"{n}/cifras de venta positivas y cuadradas", not malas,
            f"{len(malas)} filas malas" if malas else f"{len(datos['ventas'])} filas")
    malas_c = [l for c in datos["compras"] for l in c["lineas"]
               if l["cantidad"] <= 0 or l["precio"] <= 0
               or abs(l["total"] - l["cantidad"] * l["precio"]) > 1]
    rep.chk(f"{n}/cifras de compra positivas y cuadradas", not malas_c,
            f"{len(malas_c)} líneas malas" if malas_c else "")

    # 3. las compras sostienen las ventas
    comp = collections.Counter()
    vend = collections.Counter()
    for c in datos["compras"]:
        for l in c["lineas"]:
            comp[l["producto"]] += l["cantidad"]
    for r in datos["ventas"]:
        vend[r["producto"]] += float(r["cantidad"])
    catalogo = set(comp)
    deficit = {p: vend[p] - comp[p] for p in catalogo if vend[p] > comp[p]}
    rep.chk(f"{n}/las compras sostienen las ventas", not deficit, str(deficit or ""))

    # 4. todo XML cuadra
    descuadres = [c["archivo"] for c in datos["compras"]
                  if abs(sum(l["total"] for l in c["lineas"])
                         + c["cabecera"]["impuesto"] - c["cabecera"]["pagar"]) >= 1]
    rep.chk(f"{n}/|Σ líneas + impuesto − PayableAmount| < 1", not descuadres,
            str(descuadres or f"{len(datos['compras'])} facturas"))

    # 5. fechas dentro del período declarado
    fuera = [r["fecha"] for r in datos["ventas"]
             if not (desde <= dt.date.fromisoformat(r["fecha"]) <= hasta)]
    fuera += [str(c["cabecera"]["fecha"]) for c in datos["compras"]
              if not (desde <= c["cabecera"]["fecha"] <= hasta)]
    rep.chk(f"{n}/fechas dentro del período", not fuera, str(fuera[:3]))

    # 6. ningún archivo menciona productos ni proveedores de otro negocio
    ajenos = set()
    for otro, cat in catalogos.items():
        if otro != n:
            ajenos |= (catalogo & cat)
    rep.chk(f"{n}/no menciona productos de otro negocio", not ajenos,
            str(sorted(ajenos)[:3]))
    provs = {c["cabecera"]["proveedor"] for c in datos["compras"]}
    compartidos = {p for p in provs
                   if proveedores_globales[p] > 1}
    rep.chk(f"{n}/no comparte proveedores con otro negocio", not compartidos,
            str(sorted(compartidos)))

    # 7. el escenario contiene lo que declara, contra el oráculo
    disparan = set(orc["reglas"])
    faltan = set(esc["reglas_esperadas"]) - disparan
    sobran = set(esc["reglas_prohibidas"]) & disparan
    rep.chk(f"{n}/el oráculo ve las reglas esperadas", not faltan,
            f"faltan {sorted(faltan)}" if faltan else str(esc["reglas_esperadas"]))
    rep.chk(f"{n}/el oráculo no ve las prohibidas", not sobran,
            f"aparecen {sorted(sobran)}" if sobran else "")

    # 8. >=13 meses donde se declara vs_ano_anterior
    meses = len(esc["carga"]["meses"])
    if "vs_ano_anterior" in esc["reglas_esperadas"]:
        rep.chk(f"{n}/tiene 13 meses o más de historia", meses >= 13,
                f"{meses} meses")

    # 9. la compuerta de calidad
    for mes in esc["carga"]["meses"]:
        for nombre in mes["ventas"]:
            filas = [r for r in datos["ventas"] if r["archivo"] == nombre]
            malas = sum(1 for r in filas if not _fecha_ok(r["fecha"]))
            pct = malas * 100.0 / max(len(filas), 1)
            if pct > U["max_pct_nulos"]:
                rep.chk(f"{n}/{nombre} bajo la compuerta de calidad", False,
                        f"{pct:.0f}% sin fecha")
    rep.chk(f"{n}/ningún documento normal supera el {U['max_pct_nulos']}% de nulos",
            True, f"{sum(len(m['ventas']) for m in esc['carga']['meses'])} archivos")
    for nombre, filas in datos["rechazables"]:
        malas = sum(1 for r in filas if not _fecha_ok(r["fecha"]))
        pct = malas * 100.0 / max(len(filas), 1)
        rep.chk(f"{n}/{nombre} sí supera la compuerta (a propósito)",
                pct > U["max_pct_nulos"], f"{pct:.0f}% sin fecha")

    # 10. plan pro y NIT válido
    ncfg = esc["carga"]["negocio"]
    base, _, dv = ncfg["nit"].partition("-")
    rep.chk(f"{n}/nace con plan pro y NIT válido",
            ncfg["plan"] == "pro" and dv and nit_dv(base) == int(dv),
            ncfg["nit"])
    nits = [p["nit"] for p in esc["carga"]["proveedores"]]
    rep.chk(f"{n}/los NIT de proveedor tienen dígito de verificación válido",
            all(nit_dv(x.split("-")[0]) == int(x.split("-")[1]) for x in nits),
            f"{len(nits)} proveedores")


def _fecha_ok(t):
    try:
        dt.date.fromisoformat(t)
        return True
    except ValueError:
        return False


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def _corto(ruta):
    try:
        return str(ruta.relative_to(RAIZ))
    except ValueError:
        return str(ruta)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--manifest", type=pathlib.Path,
                   default=MANIFIESTOS / "scenarios.json")
    p.add_argument("--sin-base", action="store_true",
                   help="no comparar los umbrales contra la tabla `parametros`")
    args = p.parse_args()

    if not args.manifest.exists():
        sys.exit(f"no encuentro {args.manifest}: corré bin/gen_datos_prueba.py")
    man = json.loads(args.manifest.read_text())
    base = args.manifest.parent.parent
    rep = Reporte()

    print(f"validando {len(man['escenarios'])} escenarios del perfil "
          f"{man['perfil']} (seed {man['seed']})\n")

    # 1. sin ids duplicados ni FKs imposibles: acá el equivalente es que cada
    # negocio, NIT, chat_id y número de factura sea único en todo el dataset.
    vistos = collections.Counter()
    for esc in man["escenarios"]:
        c = esc["carga"]["negocio"]
        vistos[("nombre", c["nombre"])] += 1
        vistos[("nit", c["nit"])] += 1
        vistos[("chat", c["chat_id"])] += 1
    dupes = [k for k, v in vistos.items() if v > 1]
    rep.chk("global/identidades de negocio únicas", not dupes, str(dupes))

    todo = {}
    catalogos = {}
    proveedores_globales = collections.Counter()
    for esc in man["escenarios"]:
        datos = cargar_escenario(base, esc)
        todo[esc["escenario"]] = datos
        catalogos[esc["escenario"]] = {l["producto"] for c in datos["compras"]
                                       for l in c["lineas"]}
        for prov in {c["cabecera"]["proveedor"] for c in datos["compras"]}:
            proveedores_globales[prov] += 1

    oraculos = []
    for esc in man["escenarios"]:
        orc = oraculo(esc, todo[esc["escenario"]])
        oraculos.append(orc)
        validar(esc, todo[esc["escenario"]], orc, rep, catalogos,
                proveedores_globales)

    # Los umbrales con los que se generó tienen que seguir siendo los de la base.
    if not args.sin_base:
        e = env()
        claves = ",".join(f"'{k}'" for k in U if k != "max_pct_nulos")
        filas = psql(e, "SELECT clave || '=' || (valor #>> '{}') FROM parametros "
                        f"WHERE clave IN ({claves}) AND negocio_id IS NULL")
        real = dict(l.split("=", 1) for l in filas.splitlines() if l)
        distintos = {k: (U[k], real.get(k)) for k in real
                     if str(U[k]) != str(real[k])}
        rep.chk("global/los umbrales del generador siguen siendo los de la base",
                not distintos, str(distintos))

    # La huella de reproducibilidad: sha256 sobre TODOS los archivos generados,
    # pasados por `norm()` —la técnica de `_norm()` en router_casos.sql, que
    # enmascara ids de secuencia y fechas ISO—. Dos corridas con la misma seed
    # dan la misma huella; una seed distinta, otra.
    h = hashlib.sha256()
    for ruta_arch in sorted(base.rglob("*")):
        if ruta_arch.is_file() and ruta_arch.parent.name != "manifests":
            h.update(ruta_arch.name.encode())
            h.update(norm(ruta_arch.read_text()).encode())
    huella = h.hexdigest()[:32]
    rep.chk("global/huella normalizada del dataset", True, huella)

    ruta = args.manifest.parent / "oracle.json"
    ruta.write_text(json.dumps({
        "generado_en": dt.datetime.now().isoformat(timespec="seconds"),
        "perfil": man["perfil"], "seed": man["seed"],
        "huella_normalizada": huella,
        "umbrales": U,
        "nota": "calculado en Python desde los archivos generados, desde la "
                "definición de cada umbral y no desde el SQL de Chasqui",
        "escenarios": oraculos,
    }, indent=2, ensure_ascii=False))
    print()
    fallaron = rep.imprimir()
    print(f"\n{_corto(ruta)}: oráculo de {len(oraculos)} escenarios")
    return 1 if fallaron else 0


if __name__ == "__main__":
    sys.exit(main())
