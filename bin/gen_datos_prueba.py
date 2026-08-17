#!/usr/bin/env python3
"""Generador reproducible de datasets de prueba para Chasqui.

Toma el dataset público UCI Online Retail II (CC BY 4.0) como fuente de
COMPORTAMIENTO —frecuencia de ventas, mezcla de productos, cantidades,
dispersión de precios, forma estacional, concentración tipo Pareto— y sintetiza
todo lo que UCI no tiene: costos, proveedores, inventario y cartera.

Escribe archivos, no filas: CSV con la cabecera de `pos_csv_generico` y facturas
UBL 2.1 parseables por `ingesta_parsear_dian`. Quien los mete a la base es
`bin/cargar_datos_prueba.py`, por la ruta real de ingesta. Este script no toca
la base ni sabe de ella.

    python3 bin/gen_datos_prueba.py \\
      --input docs/ejemplos/fuente/online_retail_II.xlsx \\
      --output docs/ejemplos/generados \\
      --profile medium --seed 20260815

Atribución: Chen, D. (2019). Online Retail II. UCI Machine Learning Repository.
https://doi.org/10.24432/C5CG6D — CC BY 4.0.
"""
import argparse
import calendar
import collections
import csv
import datetime as dt
import json
import math
import pathlib
import random
import re
import sys
import zlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from datos_prueba_comun import (  # noqa: E402
    GENERADOS, PREFIJO, RAIZ, URL_UCI,
    leer_fuente, nit_con_dv, slug)

# ---------------------------------------------------------------------------
# Constantes de transformación, todas explícitas y documentadas
# ---------------------------------------------------------------------------

# UCI cotiza en libras. Los umbrales de priorización de Chasqui trabajan sobre
# `base_mes` en pesos: sin escalar, la relevancia de cada recomendación no se
# parecería a la de un negocio colombiano. No es una cotización: es un factor de
# escala redondo y declarado, para que las cifras se lean como pesos de verdad.
FX_GBP_COP = 5000

# Los precios de un negocio colombiano no tienen decimales sueltos.
REDONDEO = 50

# Los umbrales EFECTIVOS de la tabla `parametros` el 2026-08-16. Están acá y no
# consultados a la base a propósito: el generador no depende de la base. Que
# sigan siendo estos lo comprueba `bin/validar_datos_prueba.py` contra la base,
# y si alguien los mueve la validación falla a la vista.
UMBRALES = {
    "margen_minimo_pct": 15,
    "deriva_costo_alerta_pct": 10,
    "dias_cobertura_min": 7,
    "rotacion_lenta_dias": 60,
    "dependencia_proveedor_pct": 50,
    "dias_sin_venta_alerta": 45,
    "ventas_minimas_historicas": 3,
    "subidas_proveedor_alerta": 3,
    "caida_margen_pp_alerta": 3,
    "caida_anual_pct_alerta": 15,
    "cartera_mora_dias": 15,
    "max_pct_nulos": 20,
}

# `lineas_mes` es el tope de líneas de venta por negocio y por mes. Es lo que
# fija el tamaño del dataset —y el tiempo de carga, que es lo que de verdad
# duele: cada archivo viaja a `ingesta_cargar_tabular` como un literal JSON
# embebido en el SQL (C5)—. Las líneas que se conservan salen de UCI por sorteo
# con la seed, así que la mezcla de productos y la concentración se mantienen.
PERFILES = {
    "small":  {"negocios": 3,  "meses": 6,  "productos": 12, "lineas_mes": 140},
    "medium": {"negocios": 12, "meses": 15, "productos": 14, "lineas_mes": 280},
    "large":  {"negocios": 20, "meses": 24, "productos": 18, "lineas_mes": 420},
}

# Coberturas objetivo en días. Son lo que decide `agota` (< 7) y `quieto` (> 60),
# así que se fijan por construcción y no se dejan al azar.
COB_NORMAL, COB_AGOTA, COB_QUIETO = 25, 3, 150

MARGEN_SANO = 0.32          # 32% — cómodamente encima del 15% mínimo
MARGEN_BAJO = 0.10          # 10% — dispara `margen`
MARGEN_REPARADO = 0.30      # a lo que sube el precio tras la acción del dueño
# +40% de punta a punta y una subida por mes. El total dispara `costo` (>=10%)
# y las subidas disparan `proveedor_sube` (>=3); el TAMAÑO del escalón mensual
# es lo que decide `margen_cae`, que exige tres mediciones seguidas cayendo y
# al menos 3 puntos porcentuales entre la primera y la última. Con una rampa
# suave el margen baja medio punto por mes y la regla no puede verlo.
RAMPA_COSTO = 0.40

# ---------------------------------------------------------------------------
# Los doce escenarios
# ---------------------------------------------------------------------------
# `tendencia` es el factor multiplicativo de ventas del último mes respecto del
# primero; `estacional` amplifica la forma estacional que trae UCI.
ESCENARIOS = [
    {"nombre": "saludable",
     "esperadas": [], "prohibidas": ["costo", "proveedor", "margen", "agota",
                                     "quieto", "dependencia", "sin_ventas",
                                     "proveedor_sube", "margen_cae",
                                     "vs_ano_anterior", "cartera"],
     "cartera": "al_dia"},
    {"nombre": "margen_bajo", "margen_bajo": 4,
     "esperadas": ["margen"], "prohibidas": ["costo", "agota"]},
    # El costo se le escapa y el precio no se mueve: sube el costo, el
    # proveedor sube una y otra vez, el margen se viene cayendo y termina por
    # debajo del mínimo. Las cuatro son consecuencia de lo mismo y por eso las
    # cuatro se declaran.
    {"nombre": "costos_crecientes", "costo_sube": 4,
     "esperadas": ["costo", "proveedor_sube", "margen_cae", "margen"],
     "prohibidas": ["quieto"]},
    {"nombre": "inventario_excesivo", "quietos": 3,
     "esperadas": ["quieto"], "prohibidas": ["agota"]},
    {"nombre": "productos_agotandose", "agotan": 3,
     "esperadas": ["agota"], "prohibidas": ["quieto"]},
    {"nombre": "proveedor_caro", "caros": 3, "proveedores": 4,
     "esperadas": ["proveedor", "cartera"], "prohibidas": ["dependencia"],
     "cartera": "vencida"},
    {"nombre": "ventas_decrecientes", "sin_ventas": 2, "tendencia": 0.55,
     "esperadas": ["sin_ventas", "vs_ano_anterior"], "prohibidas": ["agota"]},
    {"nombre": "ventas_crecientes", "tendencia": 1.45,
     "esperadas": [], "prohibidas": ["sin_ventas", "vs_ano_anterior",
                                     "margen", "costo"]},
    {"nombre": "estacional", "estacional": 2.6,
     "esperadas": [], "prohibidas": ["vs_ano_anterior", "sin_ventas"]},
    # `agota` está declarado porque el conteo final que contradice la
    # estimación lo produce: antes del conteo el producto parecía `quieto`.
    {"nombre": "datos_incompletos", "sucio": True, "conteo_contradice": True,
     "esperadas": ["cartera", "agota"], "prohibidas": [], "cartera": "vencida"},
    {"nombre": "multiples_proveedores", "proveedores": 4, "dominante": True,
     "esperadas": ["dependencia"], "prohibidas": ["proveedor", "cartera"],
     "cartera": "vencida_pagada"},
    {"nombre": "accion_exitosa", "margen_bajo": 2, "accion": "precio",
     "esperadas": [], "prohibidas": ["margen"],
     "resultado_esperado": "positivo"},
]

# El perfil `small` corre tres escenarios; con 6 meses no alcanza para las
# reglas que necesitan trece (vs_ano_anterior) y eso está declarado.
SMALL = ["saludable", "margen_bajo", "productos_agotandose"]

CABECERA_VENTAS = ["fecha", "producto", "categoria", "cantidad",
                   "precio_unitario", "total"]


# ---------------------------------------------------------------------------
# Utilidades de calendario y números
# ---------------------------------------------------------------------------
def hache(*partes):
    """Hash estable entre corridas. `hash()` de Python está aleatorizado por
    proceso (PYTHONHASHSEED), y con él dos corridas de la misma seed darían
    EAN y números de factura distintos."""
    return zlib.crc32("|".join(str(x) for x in partes).encode())


def redondear(v, paso=REDONDEO):
    return max(paso, int(round(v / paso)) * paso)


def fin_de_mes(a, m):
    return dt.date(a, m, calendar.monthrange(a, m)[1])


def sumar_meses(a, m, k):
    t = (a * 12 + (m - 1)) + k
    return t // 12, t % 12 + 1


def dia_valido(a, m, d):
    return dt.date(a, m, min(d, calendar.monthrange(a, m)[1]))


# ---------------------------------------------------------------------------
# 1. Lectura y agregación de UCI
# ---------------------------------------------------------------------------
def cargar_uci(ruta):
    """Agrega UCI por StockCode y guarda las líneas utilizables.

    Decisiones sobre los datos crudos, todas explícitas:
      * `Quantity < 0` y `InvoiceNo` con prefijo C son devoluciones y
        cancelaciones. Chasqui no tiene un tipo de movimiento para eso
        ('ajuste' existe en el ENUM pero no lo produce ni lo consume nadie), así
        que salen del flujo principal. Se cuentan aparte.
      * `Description` vacía queda registrada: es el material natural de los
        escenarios de matching sucio.
      * precio 0 o cantidad 0 se descartan: no son ventas.
    """
    catalogo = {}
    devoluciones = 0
    sin_desc = 0
    mes_valor = collections.Counter()

    for r in leer_fuente(ruta):
        try:
            qty = float(r["cantidad"] or 0)
            precio = float(r["precio"] or 0)
        except ValueError:
            continue
        fecha = dt.datetime.fromisoformat(r["fecha"])
        if qty < 0 or (r["factura"] or "").upper().startswith("C"):
            devoluciones += 1
            continue
        if qty <= 0 or precio <= 0:
            continue
        desc = (r["descripcion"] or "").strip()
        if not desc:
            sin_desc += 1
            continue

        c = catalogo.get(r["codigo"])
        if c is None:
            c = catalogo[r["codigo"]] = {
                "codigo": r["codigo"], "descripciones": collections.Counter(),
                "precios": [], "lineas": [], "unidades": 0.0}
        c["descripciones"][desc] += 1
        c["precios"].append(precio)
        c["unidades"] += qty
        c["lineas"].append((fecha.date(), qty))
        mes_valor[(fecha.year, fecha.month)] += qty * precio

    for c in catalogo.values():
        c["descripcion"] = c["descripciones"].most_common(1)[0][0]
        c["precios"].sort()
        c["precio"] = c["precios"][len(c["precios"]) // 2]     # mediana
        c["n"] = len(c["lineas"])

    return {"catalogo": catalogo, "devoluciones": devoluciones,
            "sin_descripcion": sin_desc, "mes_valor": mes_valor}


def nombre_usable(desc):
    """Descripciones que sirven como nombre de producto en un CSV de POS."""
    d = desc.strip()
    if not (6 <= len(d) <= 42):
        return False
    if not re.fullmatch(r"[A-Za-z0-9 ,./&'+-]+", d):
        return False
    # Las anotaciones internas del dataset ("check", "damaged", "?") no son
    # productos: son notas del operador. No se usan como catálogo.
    return bool(re.search(r"[A-Za-z]{3}", d))


def seleccionar_productos(uci, azar, n_negocios, n_por_negocio):
    """Reparte el catálogo de UCI en tajadas DISJUNTAS, una por negocio.

    Disjuntas por construcción: es la única forma de que la prueba de
    aislamiento (§14.6) no dependa de que nadie se equivoque después.
    """
    aptos = [c for c in uci["catalogo"].values()
             if c["n"] >= 60 and nombre_usable(c["descripcion"])
             and 0.30 <= c["precio"] <= 60.0]
    # Se ordenan por popularidad y se barajan con la semilla: el dataset
    # conserva la concentración tipo Pareto de UCI, pero qué producto le toca a
    # qué negocio depende de la seed.
    aptos.sort(key=lambda c: (-c["n"], c["codigo"]))
    necesarios = n_negocios * n_por_negocio + 40      # +40 para el pozo sucio
    if len(aptos) < necesarios:
        sys.exit(f"UCI solo da {len(aptos)} productos usables y hacen falta "
                 f"{necesarios}: bajá --profile o revisá el archivo de entrada")
    elegidos = aptos[:necesarios]
    azar.shuffle(elegidos)
    tajadas = [elegidos[i * n_por_negocio:(i + 1) * n_por_negocio]
               for i in range(n_negocios)]
    pozo_sucio = elegidos[n_negocios * n_por_negocio:]
    return tajadas, pozo_sucio


def indice_estacional(productos):
    """Índice de estacionalidad 1..12, de los propios productos del negocio.

    Se promedia sobre los dos años de UCI, así que el índice de cada mes es el
    MISMO en los dos años del dataset generado. Es deliberado: `vs_ano_anterior`
    compara un mes contra el mismo mes del año anterior, y una estacionalidad
    que no se repite haría de cada diciembre una caída inventada.
    """
    por_mes = collections.Counter()
    for p in productos:
        for fecha, qty in p["lineas"]:
            por_mes[fecha.month] += qty
    total = sum(por_mes.values()) or 1
    media = total / 12.0
    return {m: (por_mes.get(m, 0) / media) or 1.0 for m in range(1, 13)}


# ---------------------------------------------------------------------------
# 2. Calendario sintético: re-anclaje a current_date (C3)
# ---------------------------------------------------------------------------
def calendario(meses, hoy):
    """Los `meses` meses COMPLETOS que terminan el mes pasado.

    El último mes es completo a propósito: `vs_ano_anterior` solo compara meses
    completos, y un agosto a medias contra un agosto entero siempre daría caída.
    """
    a, m = sumar_meses(hoy.year, hoy.month, -1)
    fin = fin_de_mes(a, m)
    lista = []
    for i in range(meses - 1, -1, -1):
        aa, mm = sumar_meses(a, m, -i)
        lista.append((aa, mm))
    return lista, fin


def ancla_uci(uci, cal):
    """Qué mes de UCI le toca a cada mes sintético.

    Se busca el mes de UCI con el MISMO mes del año que el último mes sintético
    y con suficiente historia detrás. Alinear el mes del año hace que la forma
    estacional de UCI caiga sobre el mes que le corresponde del calendario
    colombiano, y que la comparación interanual compare estacionalidades
    iguales.
    """
    meses_uci = sorted(uci["mes_valor"])
    ultimo_a, ultimo_m = cal[-1]
    candidatos = [i for i, (a, m) in enumerate(meses_uci)
                  if m == ultimo_m and i >= len(cal) - 1]
    if not candidatos:
        # Sin alineación posible (perfil muy largo): se usa el final de UCI.
        base = len(meses_uci) - 1
    else:
        base = candidatos[-1]
    return {cal[k]: meses_uci[base - (len(cal) - 1 - k)] for k in range(len(cal))}


# ---------------------------------------------------------------------------
# 3. Ventas de un negocio
# ---------------------------------------------------------------------------
def ventas_negocio(esc, productos, cal, mapa, azar, tope):
    """Filas de venta por mes, con la irregularidad de UCI y la forma declarada.

    Cada fila conserva el día del mes y la cantidad de una línea real de UCI. Lo
    único que se interviene es la ESCALA mensual: el total de cada mes se lleva
    a `objetivo`, que es la forma estacional del propio negocio por la tendencia
    que el escenario declara. Así la irregularidad de adentro del mes es real y
    la película de los meses es la que la prueba necesita.
    """
    estacional = indice_estacional(productos)
    amp = esc.get("estacional", 1.0)
    tendencia_fin = esc.get("tendencia", 1.0)
    M = len(cal)

    # Ruido correlacionado a doce meses: el mes i y el i-12 llevan el MISMO
    # ruido. Sin esto, dos sorteos independientes podrían hacer que un negocio
    # con tendencia plana pareciera caer 15% contra el año pasado.
    ruido = {}
    for i in range(M):
        if i >= 12 and (i - 12) in ruido:
            ruido[i] = ruido[i - 12]
        else:
            ruido[i] = azar.uniform(0.94, 1.06)

    crudo = {}          # (i, codigo) -> [(fecha, cantidad)]
    for p in productos:
        por_mes = collections.defaultdict(list)
        for fecha, qty in p["lineas"]:
            por_mes[(fecha.year, fecha.month)].append((fecha.day, qty))
        for i, (a, m) in enumerate(cal):
            for dia, qty in por_mes.get(mapa[(a, m)], []):
                crudo.setdefault((i, p["codigo"]), []).append(
                    (dia_valido(a, m, dia), qty))

    # Tope de líneas por mes. Se sortea sobre el conjunto del mes entero, no
    # producto por producto: así los productos que más se mueven siguen
    # llevándose la mayor parte de las líneas, que es la forma de UCI.
    for i in range(M):
        del_mes = [(cod, k) for (j, cod) in crudo if j == i
                   for k in range(len(crudo[(i, cod)]))]
        if len(del_mes) <= tope:
            continue
        quedan = set(azar.sample(del_mes, tope))
        for (j, cod) in list(crudo):
            if j != i:
                continue
            crudo[(i, cod)] = [f for k, f in enumerate(crudo[(i, cod)])
                               if (cod, k) in quedan]
            if not crudo[(i, cod)]:
                del crudo[(i, cod)]

    # Escala mensual
    actual = collections.Counter()
    for (i, cod), filas in crudo.items():
        actual[i] += sum(q for _, q in filas)
    media = (sum(actual.values()) / M) if M else 0

    filas_mes = collections.defaultdict(list)
    for i, (a, m) in enumerate(cal):
        if not actual[i]:
            continue
        est = 1.0 + amp * (estacional[m] - 1.0)
        tend = 1.0 + (tendencia_fin - 1.0) * (i / max(M - 1, 1))
        objetivo = media * max(est, 0.15) * tend * ruido[i]
        f = objetivo / actual[i]
        for p in productos:
            for fecha, qty in crudo.get((i, p["codigo"]), []):
                cant = max(1, int(round(qty * f)))
                filas_mes[i].append({"fecha": fecha, "producto": p,
                                     "cantidad": cant})
    for i in filas_mes:
        filas_mes[i].sort(key=lambda r: (r["fecha"], r["producto"]["codigo"]))
    return filas_mes, {"estacional": estacional, "amp": amp,
                       "tendencia": tendencia_fin, "ruido": ruido}


def asegurar_cola(filas_mes, productos, cal, marcados_sin_ventas, azar):
    """Todo producto vende en el último mes, salvo los marcados `sin_ventas`.

    `sin_ventas` dispara con 45 días sin vender medidos contra el último dato.
    Sin esta garantía, cualquier producto que UCI dejara de mover al final
    ensuciaría los escenarios que prohíben esa regla — y el escenario que sí la
    quiere dejaría de ser el único.
    """
    ultimo = len(cal) - 1
    a, m = cal[ultimo]
    vistos = {r["producto"]["codigo"] for r in filas_mes.get(ultimo, [])}
    for p in productos:
        if p["codigo"] in marcados_sin_ventas or p["codigo"] in vistos:
            continue
        cant = max(1, int(round(p["unidades"] / max(p["n"], 1))))
        filas_mes.setdefault(ultimo, []).append({
            "fecha": dia_valido(a, m, azar.randrange(6, 26)),
            "producto": p, "cantidad": cant})
    if ultimo in filas_mes:
        filas_mes[ultimo].sort(key=lambda r: (r["fecha"], r["producto"]["codigo"]))


# ---------------------------------------------------------------------------
# 4. Un negocio completo
# ---------------------------------------------------------------------------
class Negocio:
    def __init__(self, esc, idx, productos, pozo_sucio, cal, mapa, azar, tope):
        self.esc = esc
        self.escenario = esc["nombre"]
        self.nombre = PREFIJO + esc["nombre"]
        self.slug = slug(esc["nombre"])
        self.nit = nit_con_dv(901000000 + idx * 37)
        self.chat_id = 888001 + idx
        self.cal = cal
        self.azar = azar
        self.productos = productos
        self.pozo_sucio = pozo_sucio
        self.eventos = []
        self.marcados = {}

        self._marcar()
        self.ventas, self.forma = ventas_negocio(esc, productos, cal, mapa,
                                                 azar, tope)
        asegurar_cola(self.ventas, productos,
                      cal, self.marcados.get("sin_ventas", set()), azar)
        if esc.get("sin_ventas"):
            self._parar_ventas()
        self._precios()
        if esc.get("sucio"):
            self._ensuciar()
        self._normalizar_valor()
        self._proveedores()
        self._compras()
        self._inventario()
        self._cartera()

    # -- marcado de productos ------------------------------------------------
    def _marcar(self):
        """Qué producto lleva qué intervención. El orden es estable con la seed."""
        libres = [p["codigo"] for p in self.productos]
        def tomar(n):
            elegidos, resto = libres[:n], libres[n:]
            libres[:] = resto
            return set(elegidos)

        e = self.esc
        self.marcados["margen_bajo"] = tomar(e.get("margen_bajo", 0))
        self.marcados["costo_sube"] = tomar(e.get("costo_sube", 0))
        self.marcados["quieto"] = tomar(e.get("quietos", 0))
        self.marcados["agota"] = tomar(e.get("agotan", 0))
        self.marcados["caro"] = tomar(e.get("caros", 0))
        self.marcados["sin_ventas"] = tomar(e.get("sin_ventas", 0))
        self.marcados["contradice"] = (tomar(1) if e.get("conteo_contradice")
                                       else set())

    def _parar_ventas(self):
        """Los marcados dejan de venderse los últimos tres meses."""
        corte = max(len(self.cal) - 3, 1)
        cods = self.marcados["sin_ventas"]
        for i in range(corte, len(self.cal)):
            self.ventas[i] = [r for r in self.ventas.get(i, [])
                              if r["producto"]["codigo"] not in cods]
        for c in sorted(cods):
            self.eventos.append(
                f"{self._desc(c)} deja de venderse los últimos 3 meses")

    def _desc(self, codigo):
        return next(p["descripcion"] for p in self.productos
                    if p["codigo"] == codigo)

    # -- precios y costos ----------------------------------------------------
    def _precios(self):
        """Precio de venta por producto y mes, y costo de compra por mes.

        `v_precio_actual_producto` es el valor unitario de la ÚLTIMA venta y
        `v_costo_actual_producto` el de la ÚLTIMA compra: el margen que ve
        Chasqui es el de la punta de la serie, no un promedio. Por eso el
        control de los escenarios está acá y no en el ruido.
        """
        M = len(self.cal)
        self.precio = {}
        self.costo = {}
        mes_accion = M // 3            # el tramo donde el dueño actúa
        self.mes_accion = mes_accion
        for p in self.productos:
            cod = p["codigo"]
            base = redondear(p["precio"] * FX_GBP_COP)
            margen = (MARGEN_BAJO if cod in self.marcados["margen_bajo"]
                      else MARGEN_SANO)
            costo0 = redondear(base * (1 - margen))
            for i in range(M):
                precio = base
                if (self.esc.get("accion") and cod in self.marcados["margen_bajo"]
                        and i > mes_accion):
                    precio = redondear(costo0 / (1 - MARGEN_REPARADO))
                self.precio[(cod, i)] = precio
                if cod in self.marcados["costo_sube"]:
                    self.costo[(cod, i)] = redondear(
                        costo0 * (1 + RAMPA_COSTO * i / max(M - 1, 1)))
                else:
                    self.costo[(cod, i)] = costo0

        for c in sorted(self.marcados["margen_bajo"]):
            self.eventos.append(
                f"{self._desc(c)} se vende con {int(MARGEN_BAJO*100)}% de margen")
        for c in sorted(self.marcados["costo_sube"]):
            self.eventos.append(
                f"{self._desc(c)}: el costo sube {int(RAMPA_COSTO*100)}% "
                f"en {M} meses, una subida por mes")
        if self.esc.get("accion"):
            for c in sorted(self.marcados["margen_bajo"]):
                self.eventos.append(
                    f"el dueño aplica el precio sugerido para {self._desc(c)} "
                    f"en el mes {mes_accion + 1} y el margen sube a "
                    f"{int(MARGEN_REPARADO*100)}%")

    def _normalizar_valor(self):
        """Segunda pasada: la forma mensual se ajusta en PESOS, no en unidades.

        `vs_ano_anterior` compara importes. Dos meses con las mismas unidades
        pueden diferir un 30% en plata solo porque se vendió otra mezcla de
        productos, y esa diferencia se leería como una caída interanual que
        nadie diseñó. Acá el objetivo de cada mes se expresa en pesos y las
        cantidades se reescalan para alcanzarlo; la irregularidad de adentro
        del mes no se toca.
        """
        M = len(self.cal)
        f_ = self.forma

        def valor(i):
            return sum(r["cantidad"] * self.precio[(r["producto"]["codigo"], i)]
                       for r in self.ventas.get(i, []))

        vals = {i: valor(i) for i in range(M)}
        media = sum(vals.values()) / M if M else 0
        for i, (a, m) in enumerate(self.cal):
            if not vals[i]:
                continue
            est = 1.0 + f_["amp"] * (f_["estacional"][m] - 1.0)
            tend = 1.0 + (f_["tendencia"] - 1.0) * (i / max(M - 1, 1))
            objetivo = media * max(est, 0.15) * tend * f_["ruido"][i]
            fac = objetivo / vals[i]
            for r in self.ventas[i]:
                r["cantidad"] = max(1, int(round(r["cantidad"] * fac)))

    # -- proveedores ---------------------------------------------------------
    def _proveedores(self):
        n = self.esc.get("proveedores", 3)
        self.proveedores = []
        for k in range(n):
            num = PROV_CONTADOR[0]
            PROV_CONTADOR[0] += 1
            self.proveedores.append({
                "nombre": f"PROVEEDOR DEMO {num:03d}",
                "nit": nit_con_dv(830000000 + num * 1013)})

        # Reparto por carga: el proveedor con menos gasto asignado se lleva el
        # próximo producto. Deja las participaciones cerca del tercio y `31%` no
        # es `>= 50%`: ningún negocio dispara `dependencia` sin quererlo.
        gasto = {p["nombre"]: 0.0 for p in self.proveedores}
        self.prov_de = {}
        pesos = sorted(self.productos,
                       key=lambda p: -sum(r["cantidad"]
                                          for i in self.ventas
                                          for r in self.ventas[i]
                                          if r["producto"]["codigo"] == p["codigo"]))
        for p in pesos:
            if self.esc.get("dominante") and len(self.prov_de) < len(pesos) * 0.6:
                elegido = self.proveedores[0]["nombre"]
            else:
                elegido = min(gasto, key=lambda k: (gasto[k], k))
            self.prov_de[p["codigo"]] = elegido
            gasto[elegido] += sum(
                r["cantidad"] * self.costo[(p["codigo"], i)]
                for i in self.ventas for r in self.ventas[i]
                if r["producto"]["codigo"] == p["codigo"])
        if self.esc.get("dominante"):
            self.eventos.append(
                f"{self.proveedores[0]['nombre']} concentra más de la mitad "
                f"del gasto de compras")

    # -- compras -------------------------------------------------------------
    def _compras(self):
        """Las compras se derivan de las ventas, nunca al azar.

        Cada mes se compra lo que ese mes se vendió, y en el primer mes con
        ventas se compra además el colchón que deja la cobertura objetivo del
        escenario. Así nunca se vende más de lo que entró y el stock final es
        exactamente el que la regla necesita ver.
        """
        M = len(self.cal)
        vend = collections.defaultdict(float)
        fechas = collections.defaultdict(list)
        for i in range(M):
            for r in self.ventas.get(i, []):
                cod = r["producto"]["codigo"]
                vend[(cod, i)] += r["cantidad"]
                fechas[cod].append(r["fecha"])

        self.vend_pm = vend
        self.cobertura_objetivo = {}
        colchon = {}
        for p in self.productos:
            cod = p["codigo"]
            u = sum(vend[(cod, i)] for i in range(M))
            if not u or not fechas[cod]:
                continue
            ventana = max((max(fechas[cod]) - min(fechas[cod])).days, 1)
            objetivo = COB_NORMAL
            if cod in self.marcados["quieto"] or cod in self.marcados["contradice"]:
                objetivo = COB_QUIETO
            elif cod in self.marcados["agota"]:
                objetivo = COB_AGOTA
            self.cobertura_objetivo[cod] = objetivo
            b = math.ceil(objetivo * u / ventana)
            # Con pocas unidades el redondeo puede dejar la cobertura del lado
            # equivocado del umbral; se corrige subiendo de a una unidad.
            while objetivo >= COB_NORMAL and b * ventana / u < objetivo * 0.9:
                b += 1
            colchon[cod] = b

        self.colchon = colchon
        # (mes, proveedor) -> [líneas]
        self.compras = collections.defaultdict(list)
        self.comp_pm = collections.defaultdict(float)
        primero = {}
        for i in range(M):
            for p in self.productos:
                cod = p["codigo"]
                q = vend[(cod, i)]
                if not q:
                    continue
                if cod not in primero:
                    primero[cod] = i
                    q += colchon.get(cod, 0)
                prov = self.prov_de[cod]
                costo = self.costo[(cod, i)]
                # `proveedor_caro`: el mismo producto a dos proveedores. El caro
                # va primero y el barato al final, para que la deriva de costo
                # quede NEGATIVA y `costo` no dispare de rebote: lo que se
                # prueba acá es que hay dónde comprarlo más barato.
                if cod in self.marcados["caro"]:
                    if i == M - 1:
                        prov = self.proveedores[-1]["nombre"]
                        costo = redondear(costo * 0.72)
                    else:
                        prov = self.proveedores[0]["nombre"]
                self.compras[(i, prov)].append(
                    {"producto": p, "cantidad": int(math.ceil(q)),
                     "costo": costo})
                self.comp_pm[(cod, i)] += int(math.ceil(q))
        for c in sorted(self.marcados["caro"]):
            self.eventos.append(
                f"{self._desc(c)} se le compra a dos proveedores; el último mes "
                f"aparece uno 28% más barato")
        for c in sorted(self.marcados["quieto"]):
            self.eventos.append(
                f"{self._desc(c)} queda con inventario para ~{COB_QUIETO} días")
        for c in sorted(self.marcados["agota"]):
            self.eventos.append(
                f"{self._desc(c)} queda con inventario para ~{COB_AGOTA} días")

    # -- inventario ----------------------------------------------------------
    def _inventario(self):
        """Los tres orígenes de stock, más el conteo que contradice la estimación.

        Un conteo REEMPLAZA el balance estimado: `v_balance_unidades` pasa a
        contar desde el conteo. Por eso los conteos se calculan para que el
        balance final siga siendo el que la cobertura objetivo del escenario
        pide — un conteo puesto a ojo mueve `dias_cobertura` y dispara `quieto`
        o `agota` donde el escenario los prohíbe. Y por eso caen sobre
        productos SIN marcar: el producto marcado ya tiene su papel.
        """
        M = len(self.cal)
        self.conteos = collections.defaultdict(list)
        marcados = set().union(*self.marcados.values()) if self.marcados else set()
        libres = [p["codigo"] for p in self.productos
                  if p["codigo"] not in marcados
                  and self.cobertura_objetivo.get(p["codigo"])]
        if len(libres) < 2:
            return

        def acumulado(cod, hasta_mes):
            """Compras menos ventas hasta el fin del mes `hasta_mes`, inclusive."""
            c = sum(self.comp_pm.get((cod, i), 0) for i in range(hasta_mes + 1))
            v = sum(self.vend_pm.get((cod, i), 0) for i in range(hasta_mes + 1))
            return c - v

        # (a) conteo reciente sin movimientos posteriores -> origen 'conteo'.
        # Se cuenta lo que de verdad hay: el balance final estimado.
        p0 = libres[0]
        self.conteos[M - 1].append({
            "producto": self._desc(p0), "codigo": p0,
            "unidades": max(1, int(round(acumulado(p0, M - 1)))),
            "fecha": None, "situacion": "conteo"})

        # (b) conteo antiguo con movimientos después -> origen 'calculado'.
        # El valor contado es el balance de ESE día: así el balance de hoy sale
        # igual al estimado y la cobertura sigue siendo la del escenario.
        p1 = libres[1]
        medio = max(M // 2, 1)
        self.conteos[medio].append({
            "producto": self._desc(p1), "codigo": p1,
            "unidades": max(1, int(round(acumulado(p1, medio)))),
            "fecha": fin_de_mes(*self.cal[medio]).isoformat(),
            "situacion": "calculado"})

        # (c) el resto sin conteo -> origen 'estimado' (no se hace nada)
        self.eventos.append(
            f"conteos: {self._desc(p0)} recién contado (origen `conteo`), "
            f"{self._desc(p1)} contado a mitad de período (origen `calculado`), "
            f"el resto sin conteo (origen `estimado`)")

        # (d) el conteo que contradice la estimación
        for cod in sorted(self.marcados["contradice"]):
            self.conteos[M - 1].append({
                "producto": self._desc(cod), "codigo": cod, "unidades": 1,
                "fecha": None, "situacion": "contradice",
                "despues_de_registrar": True})
            self.eventos.append(
                f"{self._desc(cod)}: la estimación decía inventario para "
                f"~{COB_QUIETO} días (`quieto`) y el conteo final dice que "
                f"queda 1 unidad (`agota`)")

    # -- cartera -------------------------------------------------------------
    def _cartera(self):
        """Cuentas por cobrar por el portal. Las por pagar salen solas del XML."""
        self.facturas = collections.defaultdict(list)
        self.pagos = collections.defaultdict(list)
        modo = self.esc.get("cartera")
        if not modo:
            return
        M = len(self.cal)
        ultimo = M - 1
        venta_mes = sum(r["cantidad"] * self.precio[(r["producto"]["codigo"], ultimo)]
                        for r in self.ventas.get(ultimo, []))
        cliente = f"CLIENTE DEMO {self.slug[:12].upper()}"
        nit_cli = nit_con_dv(890000000 + self.chat_id * 7)
        hoy = dt.date.today()

        if modo == "al_dia":
            self.facturas[ultimo].append({
                "numero": f"FV-{self.slug[:6].upper()}-01",
                "tercero": cliente, "nit": nit_cli,
                "total": redondear(venta_mes * 0.20),
                "emision": hoy.isoformat(),
                "vencimiento": (hoy + dt.timedelta(days=25)).isoformat()})
            self.eventos.append("cartera al día: una factura que vence en 25 días")
            return

        # Vencida: el saldo se dimensiona contra lo que el negocio mueve en un
        # mes para que la prioridad quede en `alta` — es lo que hace posible
        # probar `alertas_evaluar`, que solo mira las altas.
        total = redondear(max(venta_mes * 0.80, 200000))
        self.facturas[ultimo].append({
            "numero": f"FV-{self.slug[:6].upper()}-01",
            "tercero": cliente, "nit": nit_cli, "total": total,
            "emision": (hoy - dt.timedelta(days=70)).isoformat(),
            "vencimiento": (hoy - dt.timedelta(days=40)).isoformat()})
        self.eventos.append(
            f"cartera vencida: ${total:,} con 40 días de mora".replace(",", "."))
        if modo == "vencida_pagada":
            self.pagos[ultimo].append({
                "numero": f"FV-{self.slug[:6].upper()}-01", "valor": total,
                "fecha": hoy.isoformat(), "despues_de_registrar": True})
            self.eventos.append(
                "el cliente paga después de que la recomendación se registró")

    # -- datos sucios --------------------------------------------------------
    def _ensuciar(self):
        """Filas que Chasqui debe conservar sin resolver, y un archivo rechazable.

        Dos cosas distintas y a propósito separadas: filas con un nombre que no
        está en el catálogo (quedan con `producto_id NULL` y alias `pendiente`,
        no desaparecen) y un documento con más del 20% de fechas ilegibles, que
        la compuerta de calidad debe rechazar entero.
        """
        M = len(self.cal)
        extras = self.pozo_sucio[:3]
        # En TODOS los meses, no solo en los últimos: unas filas extra metidas
        # al final le sumarían plata al mes de referencia y no al mismo mes del
        # año anterior, que es exactamente la caída interanual inventada que
        # este dataset trata de no producir.
        for i in range(M):
            a, m = self.cal[i]
            for k, p in enumerate(extras):
                self.precio[(p["codigo"], i)] = redondear(p["precio"] * FX_GBP_COP)
                self.ventas.setdefault(i, []).append({
                    "fecha": dia_valido(a, m, 5 + k * 7),
                    "producto": {"codigo": p["codigo"],
                                 "descripcion": p["descripcion"],
                                 "precio": p["precio"]},
                    "cantidad": 6, "huerfano": True})
            self.ventas[i].sort(key=lambda r: (r["fecha"], r["producto"]["codigo"]))
        self.eventos.append(
            f"{len(extras)} productos por mes que nunca se compraron: "
            f"quedan sin resolver, como alias pendientes")
        self.rechazable = True
        self.eventos.append(
            "un archivo extra con 40% de fechas ilegibles, para probar que la "
            "compuerta de calidad lo rechaza entero")


PROV_CONTADOR = [1]


# ---------------------------------------------------------------------------
# 5. Escritura de archivos
# ---------------------------------------------------------------------------
def escribir_ventas(neg, destino, i):
    a, m = neg.cal[i]
    filas = neg.ventas.get(i, [])
    if not filas:
        return None
    ruta = destino / f"ventas_{a:04d}{m:02d}.csv"
    with ruta.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CABECERA_VENTAS)
        w.writeheader()
        for r in filas:
            cod = r["producto"]["codigo"]
            if r.get("huerfano"):
                precio = redondear(r["producto"]["precio"] * FX_GBP_COP)
            else:
                precio = neg.precio[(cod, i)]
            w.writerow({
                "fecha": r["fecha"].isoformat(),
                "producto": r["producto"]["descripcion"],
                "categoria": "",
                "cantidad": r["cantidad"],
                "precio_unitario": precio,
                "total": r["cantidad"] * precio})
    return ruta.name


def escribir_rechazable(neg, destino):
    """Un CSV con el 40% de las fechas ilegibles: la compuerta debe tumbarlo."""
    i = len(neg.cal) - 1
    a, m = neg.cal[i]
    ruta = destino / f"ventas_{a:04d}{m:02d}_rechazable.csv"
    filas = neg.ventas.get(i, [])[:20]
    with ruta.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=CABECERA_VENTAS)
        w.writeheader()
        for k, r in enumerate(filas):
            cod = r["producto"]["codigo"]
            precio = (redondear(r["producto"]["precio"] * FX_GBP_COP)
                      if r.get("huerfano") else neg.precio[(cod, i)])
            w.writerow({
                "fecha": "ayer" if k % 5 < 2 else r["fecha"].isoformat(),
                "producto": r["producto"]["descripcion"], "categoria": "",
                "cantidad": r["cantidad"], "precio_unitario": precio,
                "total": r["cantidad"] * precio})
    return ruta.name


NS = ('xmlns="urn:oasis:names:specification:ubl:schema:xsd:Invoice-2" '
      'xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:'
      'CommonAggregateComponents-2" '
      'xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:'
      'CommonBasicComponents-2"')


def ean(codigo):
    """EAN-13 sintético estable, derivado del StockCode de UCI."""
    cuerpo = f"770{hache('ean', codigo) % 10**9:09d}"
    s = sum((3 if i % 2 else 1) * int(c) for i, c in enumerate(cuerpo))
    return cuerpo + str((10 - s % 10) % 10)


def xml_factura(neg, prov, numero, emision, vence, lineas):
    """Factura UBL 2.1 con lo que `ingesta_parsear_dian` realmente lee."""
    iva = 0.19
    cuerpo = []
    total_lineas = 0
    for k, l in enumerate(lineas, 1):
        monto = l["cantidad"] * l["costo"]
        total_lineas += monto
        cuerpo.append(f"""  <cac:InvoiceLine>
    <cbc:ID>{k}</cbc:ID>
    <cbc:InvoicedQuantity unitCode="UND">{l['cantidad']}</cbc:InvoicedQuantity>
    <cbc:LineExtensionAmount currencyID="COP">{monto}.00</cbc:LineExtensionAmount>
    <cac:Item>
      <cbc:Description>{escapar(l['producto']['descripcion'])}</cbc:Description>
      <cac:StandardItemIdentification>
        <cbc:ID schemeID="999">{ean(l['producto']['codigo'])}</cbc:ID>
      </cac:StandardItemIdentification>
    </cac:Item>
    <cac:Price>
      <cbc:PriceAmount currencyID="COP">{l['costo']}.00</cbc:PriceAmount>
    </cac:Price>
  </cac:InvoiceLine>""")
    impuesto = int(round(total_lineas * iva))
    pagar = total_lineas + impuesto
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Invoice {NS}>
  <cbc:ID>{numero}</cbc:ID>
  <cbc:IssueDate>{emision}</cbc:IssueDate>
  <cbc:DueDate>{vence}</cbc:DueDate>
  <cbc:DocumentCurrencyCode>COP</cbc:DocumentCurrencyCode>
  <cac:AccountingSupplierParty>
    <cac:Party>
      <cac:PartyTaxScheme>
        <cbc:RegistrationName>{escapar(prov['nombre'])}</cbc:RegistrationName>
        <cbc:CompanyID schemeName="31">{prov['nit']}</cbc:CompanyID>
      </cac:PartyTaxScheme>
    </cac:Party>
  </cac:AccountingSupplierParty>
  <cac:AccountingCustomerParty>
    <cac:Party>
      <cac:PartyTaxScheme>
        <cbc:RegistrationName>{escapar(neg.nombre)}</cbc:RegistrationName>
        <cbc:CompanyID schemeName="31">{neg.nit}</cbc:CompanyID>
      </cac:PartyTaxScheme>
    </cac:Party>
  </cac:AccountingCustomerParty>
  <cac:TaxTotal>
    <cbc:TaxAmount currencyID="COP">{impuesto}.00</cbc:TaxAmount>
  </cac:TaxTotal>
  <cac:LegalMonetaryTotal>
    <cbc:LineExtensionAmount currencyID="COP">{total_lineas}.00</cbc:LineExtensionAmount>
    <cbc:PayableAmount currencyID="COP">{pagar}.00</cbc:PayableAmount>
  </cac:LegalMonetaryTotal>
{chr(10).join(cuerpo)}
</Invoice>
"""


def envolver_adjunto(xml, numero):
    """Lo que llega por correo en la vida real: el Invoice dentro de un CDATA."""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<AttachedDocument xmlns="urn:oasis:names:specification:ubl:schema:xsd:AttachedDocument-2"
  xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
  xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">
  <cbc:ID>{numero}</cbc:ID>
  <cac:Attachment>
    <cac:ExternalReference>
      <cbc:Description><![CDATA[{xml}]]></cbc:Description>
    </cac:ExternalReference>
  </cac:Attachment>
</AttachedDocument>
"""


def escapar(t):
    return (t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def escribir_compras(neg, destino, i):
    a, m = neg.cal[i]
    nombres = []
    for prov in neg.proveedores:
        lineas = neg.compras.get((i, prov["nombre"]), [])
        if not lineas:
            continue
        numero = (f"SETP{hache(neg.slug, prov['nombre']) % 9000 + 1000}"
                  f"-{a}{m:02d}")
        emision = dia_valido(a, m, 3).isoformat()
        vence = (dia_valido(a, m, 3) + dt.timedelta(days=30)).isoformat()
        xml = xml_factura(neg, prov, numero, emision, vence, lineas)
        # El primer documento de cada negocio va como AttachedDocument: es el
        # formato con el que llegan de verdad por correo, y hay que probarlo.
        adjunto = not nombres and i == min(k for k, _ in neg.compras)
        ruta = destino / (f"compra_{a:04d}{m:02d}_"
                          f"{slug(prov['nombre'])}"
                          f"{'_adjunta' if adjunto else ''}.xml")
        ruta.write_text(envolver_adjunto(xml, numero) if adjunto else xml)
        nombres.append(ruta.name)
    return nombres


# ---------------------------------------------------------------------------
# 6. Manifest
# ---------------------------------------------------------------------------
def manifest_negocio(neg, seed, salida):
    meses = []
    destino = salida / neg.slug
    for i, (a, m) in enumerate(neg.cal):
        entrada = {
            "mes": f"{a:04d}-{m:02d}",
            "hasta": fin_de_mes(a, m).isoformat(),
            "ventas": [x for x in [escribir_ventas(neg, destino, i)] if x],
            "compras": escribir_compras(neg, destino, i),
            "conteos": neg.conteos.get(i, []),
            "facturas": neg.facturas.get(i, []),
            "pagos": neg.pagos.get(i, []),
            "acciones": [],
        }
        if neg.esc.get("accion") and i == neg.mes_accion:
            for cod in sorted(neg.marcados["margen_bajo"]):
                entrada["acciones"].append({
                    "regla": "margen", "producto": neg._desc(cod),
                    "accion": neg.esc["accion"]})
        meses.append(entrada)
    if getattr(neg, "rechazable", False):
        meses[-1]["rechazables"] = [escribir_rechazable(neg, destino)]

    return {
        "escenario": neg.escenario,
        "negocio": neg.nombre,
        "seed": seed,
        "periodo": {"desde": dt.date(neg.cal[0][0], neg.cal[0][1], 1).isoformat(),
                    "hasta": fin_de_mes(*neg.cal[-1]).isoformat()},
        "productos": [p["descripcion"] for p in neg.productos],
        "proveedores": [p["nombre"] for p in neg.proveedores],
        "eventos": neg.eventos,
        "reglas_esperadas": neg.esc["esperadas"],
        "reglas_prohibidas": neg.esc["prohibidas"],
        "estado_esperado": (
            {"recomendaciones.estado": "vigente"} if neg.esc["esperadas"]
            else {"recomendaciones": "ninguna vigente"}) |
            ({"recomendaciones.resultado": neg.esc["resultado_esperado"]}
             if neg.esc.get("resultado_esperado") else {}),
        "carga": {
            "negocio": {"nombre": neg.nombre, "nit": neg.nit,
                        "plan": "pro", "chat_id": neg.chat_id},
            "proveedores": neg.proveedores,
            "meses": meses,
        },
        "marcados": {k: sorted(neg._desc(c) for c in v)
                     for k, v in neg.marcados.items() if v},
        "cobertura_objetivo_dias": {neg._desc(c): d
                                    for c, d in neg.cobertura_objetivo.items()
                                    if d != COB_NORMAL},
    }


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def _corto(ruta):
    """La ruta relativa a la raíz si está adentro, y si no la absoluta."""
    try:
        return str(ruta.relative_to(RAIZ))
    except ValueError:
        return str(ruta)


def main():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--input", type=pathlib.Path,
                   default=RAIZ / "docs/ejemplos/fuente/online_retail_II.xlsx")
    p.add_argument("--output", type=pathlib.Path, default=GENERADOS)
    p.add_argument("--profile", choices=sorted(PERFILES), default="medium")
    p.add_argument("--seed", type=int, default=20260815)
    args = p.parse_args()

    perfil = PERFILES[args.profile]
    azar = random.Random(args.seed)
    PROV_CONTADOR[0] = 1

    print(f"perfil {args.profile}: {perfil['negocios']} negocios, "
          f"{perfil['meses']} meses, {perfil['productos']} productos c/u")
    uci = cargar_uci(args.input)
    print(f"  UCI: {len(uci['catalogo']):,} productos, "
          f"{uci['devoluciones']:,} devoluciones descartadas, "
          f"{uci['sin_descripcion']:,} filas sin descripción"
          .replace(",", "."))

    escenarios = ESCENARIOS
    if args.profile == "small":
        escenarios = [e for e in ESCENARIOS if e["nombre"] in SMALL]
    elif args.profile == "large":
        extra = [dict(e, nombre=e["nombre"] + "_b")
                 for e in ESCENARIOS[:perfil["negocios"] - len(ESCENARIOS)]]
        escenarios = ESCENARIOS + extra
    escenarios = escenarios[:perfil["negocios"]]

    tajadas, pozo = seleccionar_productos(uci, azar, len(escenarios),
                                          perfil["productos"])
    cal, fin = calendario(perfil["meses"], dt.date.today())
    mapa = ancla_uci(uci, cal)
    print(f"  calendario: {cal[0][0]}-{cal[0][1]:02d} .. {fin} "
          f"(anclado a UCI {mapa[cal[0]]} .. {mapa[cal[-1]]})")

    salida = args.output
    (salida / "manifests").mkdir(parents=True, exist_ok=True)
    escenas = []
    for idx, esc in enumerate(escenarios):
        neg = Negocio(esc, idx, tajadas[idx], pozo, cal, mapa,
                      random.Random(args.seed + idx * 101), perfil["lineas_mes"])
        (salida / neg.slug).mkdir(parents=True, exist_ok=True)
        # limpieza: una corrida nueva no debe dejar archivos de la anterior
        for viejo in (salida / neg.slug).glob("*"):
            viejo.unlink()
        escenas.append(manifest_negocio(neg, args.seed, salida))
        n_mov = sum(len(neg.ventas.get(i, [])) for i in range(len(cal)))
        n_com = sum(len(v) for v in neg.compras.values())
        print(f"  {neg.nombre:<34} {n_mov:>6} ventas  {n_com:>5} líneas de compra"
              f"  {len(neg.proveedores)} proveedores")

    manifest = {
        "generado_en": dt.datetime.now().isoformat(timespec="seconds"),
        "perfil": args.profile,
        "seed": args.seed,
        "fuente": {
            "dataset": "UCI Online Retail II",
            "url": URL_UCI,
            "licencia": "CC BY 4.0",
            "atribucion": "Chen, D. (2019). Online Retail II. UCI Machine "
                          "Learning Repository. https://doi.org/10.24432/C5CG6D",
            "archivo": args.input.name,
        },
        "transformacion": {
            "fx_gbp_cop": FX_GBP_COP,
            "redondeo_pesos": REDONDEO,
            "reanclaje": "cada mes de UCI se mapea a un mes sintético del mismo "
                         "mes del año; el último mes sintético es el último mes "
                         "completo anterior a current_date",
            "descartado": "devoluciones (Quantity<0 y facturas con prefijo C) y "
                          "filas sin descripción o con precio cero",
        },
        "umbrales_objetivo": UMBRALES,
        "escenarios": escenas,
    }
    ruta = salida / "manifests" / "scenarios.json"
    ruta.write_text(json.dumps(manifest, indent=2, ensure_ascii=False))
    total = sum(len(e["carga"]["meses"]) for e in escenas)
    print(f"\n{_corto(ruta)}: {len(escenas)} escenarios, "
          f"{total} meses de carga")


if __name__ == "__main__":
    main()
