#!/usr/bin/env python3
"""El ciclo de vida de un negocio nuevo: de cero a tres periodos cargados.

`db/pruebas/empty_state.sql` prueba el negocio vacío quieto. Esto prueba lo
otro: que ese mismo negocio pueda MOVERSE de vacío a operando, por las rutas
que usa un usuario real y en el orden en que las usa.

    negocio vacío
        ↓  /nueva → elegir servicio        (router_procesar_mensaje)
    primera factura DIAN + primer CSV      (ingesta_registrar_documento…)
        ↓  productos creados / alias resueltos
    /listo → análisis                      (ejecucion_preparar → ejecucion_cerrar)
        ↓  snapshot + recomendaciones
    segundo periodo, formato desconocido    (el sistema aprende el layout)
        ↓  comparativo contra el snapshot anterior
    tercer periodo, fuera de la ventana free
        ↓  el plan crece y la historia aparece sola

Qué es «ruta real» acá y qué no:

  * SÍ lo es toda la lógica: el router decide la sesión, `ingesta_*` registra y
    parsea los archivos reales de `docs/ejemplos/historial_6meses/`,
    `ejecucion_preparar` arma el prompt y `ejecucion_cerrar` deja snapshot y
    recomendaciones. No hay un solo INSERT directo en `movimientos`,
    `productos` ni `snapshots_negocio`.
  * NO lo es el transporte: la descarga del archivo desde Telegram y la
    extracción de filas del CSV las hacen nodos de n8n (§6.2 de la guía
    técnica). Acá el archivo se lee del disco y las filas se parsean con `csv`,
    que es exactamente lo que le llega a `ingesta_cargar_tabular` en producción.
  * El LLM queda afuera salvo con `--con-llm`, que corre wf_ejecutar de verdad.
    Sin él, el informe que se guarda es el seco (`informe_render`), que es el
    mismo camino que toma producción cuando `validar_cifras` rechaza dos veces.

    python3 bin/prueba_ciclo_vida.py
    python3 bin/prueba_ciclo_vida.py --con-llm     # corre wf_ejecutar de verdad
    python3 bin/prueba_ciclo_vida.py --limpiar     # borra el negocio y sale
"""
import argparse
import base64
import csv
import json
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from datos_prueba_comun import RAIZ, env, psql, psql_json  # noqa: E402

HISTORIAL = RAIZ / "docs" / "ejemplos" / "historial_6meses"

# El usuario de Telegram con el que se hace toda la prueba. Es el identificador
# por el que se limpia: el negocio lo nombra el router ("Mi negocio") y
# renombrarlo falsearía justamente lo que se está probando.
CHAT = 990990

# NIT sintético con dígito de verificación válido, el que el dueño escribe en el
# portal. Sin él, `cartera_facturar_dian` no puede distinguir una factura
# emitida de una recibida y toda factura entra como compra.
NIT = "901456789-0"

# Los tres periodos, en el orden en que los va a vivir el negocio.
#
# Junio y julio caen dentro de la ventana del plan free (3 meses); mayo NO, y
# por eso va al final, después de que el negocio pasa a `pro`. No es un rodeo
# para que la prueba pase: es el caso real de quien sube el historial que tiene
# y descubre que su plan no se lo lee.
PERIODOS = [
    {"nombre": "P1 junio 2026", "hasta": "2026-06-30",
     "compra": "compra_202606_colombina.xml",
     "ventas": "ventas_202606_pos_decimal_punto.csv",
     "mapeo": None},                      # huella ya conocida: pos_csv_generico
    {"nombre": "P2 julio 2026", "hasta": "2026-07-31",
     "compra": "compra_202607_fep.xml",
     "ventas": "ventas_202607_crm_tablet.csv",
     # Huella nueva. En producción este mapeo lo infiere el LLM mirando las
     # cabeceras y 5 filas (nunca las cifras); acá se escribe a mano, que es la
     # otra vía que la guía técnica (§11) admite para fijar un formato.
     "mapeo": {"columnas": {"fecha": "fecha_hora", "producto": "descripcion",
                            "categoria": "tipo", "cantidad": "cantidad_vendida",
                            "valor_unitario": "valor_unit",
                            "valor_total": "subtotal"},
               "tipo": "venta", "decimal": ".", "miles": "",
               "formato_fecha": "YYYY-MM-DD"}},
    {"nombre": "P3 mayo 2026", "hasta": None,
     "compra": "compra_202605_fep.xml",
     "ventas": "ventas_202605_pos_latam.csv",
     # Otro layout más: punto y coma, fecha dd/mm/yyyy y decimales con coma.
     "mapeo": {"columnas": {"fecha": "Fecha Venta", "producto": "Nombre Producto",
                            "categoria": "Clase", "cantidad": "Unidades",
                            "valor_unitario": "Precio Unitario",
                            "valor_total": "Valor Total"},
               "tipo": "venta", "decimal": ",", "miles": ".",
               "formato_fecha": "DD/MM/YYYY"}},
]

RESULTADOS = []


def chk(fase, prueba, esperado, obtenido):
    ok = str(esperado) == str(obtenido)
    RESULTADOS.append((fase, prueba, str(esperado), str(obtenido), ok))
    print(f"    [{'PASS' if ok else 'FALL'}] {prueba}"
          f"{'' if ok else f'  esperado={esperado} obtenido={obtenido}'}",
          flush=True)
    return ok


def sql_str(t):
    return "'" + str(t).replace("'", "''") + "'"


def dolar(texto, tag):
    assert f"${tag}$" not in texto, "el contenido choca con la cita en dólar"
    return f"${tag}${texto}${tag}$"


# ---------------------------------------------------------------------------
# Las dos rutas de entrada del usuario
# ---------------------------------------------------------------------------
def router(e, texto, doc=False):
    """Un mensaje de Telegram, tal como se lo entrega wf_router a la base."""
    evento = {"from": {"id": str(CHAT), "username": "ciclo_vida"},
              "chat": {"id": str(CHAT)}, "texto": texto}
    if doc:
        evento["tiene_documento"] = True
    return psql_json(e, f"SELECT router_procesar_mensaje("
                        f"{dolar(json.dumps(evento), 'ev')}::jsonb)")


def plantilla(r):
    """La plantilla de la primera respuesta, o '<sin respuesta>'."""
    resp = (r or {}).get("respuestas") or []
    return resp[0].get("plantilla") if resp else "<sin respuesta>"


def accion(r, tipo):
    for a in (r or {}).get("acciones") or []:
        if a.get("tipo") == tipo:
            return a
    return None


def leer_csv(ruta):
    """Lo que hace el nodo `ExtraerCSV` de wf_ingesta: filas y cabeceras."""
    with ruta.open(newline="", encoding="utf-8-sig") as f:
        primera = f.readline()
        delim = ";" if primera.count(";") > primera.count(",") else ","
        f.seek(0)
        filas = list(csv.DictReader(f, delimiter=delim))
    return filas, list(filas[0].keys())


def ingerir_ventas(e, neg, sesion, ruta, mapeo):
    """La rama tabular de wf_ingesta, con el archivo real del disco."""
    filas, columnas = leer_csv(ruta)
    contenido = base64.b64encode(ruta.read_bytes()).decode()
    cols = ",".join(sql_str(c) for c in columnas)

    ident = psql_json(e, f"""
      WITH reg AS (SELECT ingesta_registrar_documento(
                     {sesion}, {neg}, {sql_str(ruta.name)}, 'text/csv',
                     decode('{contenido}', 'base64')) AS r)
      SELECT (SELECT r FROM reg) || ingesta_identificar_tabular(
               ((SELECT r FROM reg) ->> 'documento_id')::bigint, ARRAY[{cols}])""")
    doc = ident["documento_id"]

    if ident.get("requiere_inferencia"):
        if not mapeo:
            return doc, ident, None
        # El paso que en producción hace `LeerMapeo` con la salida del LLM.
        psql(e, f"SELECT ingesta_registrar_formato_inferido({doc}, ARRAY[{cols}],"
                f" {dolar(json.dumps(mapeo), 'map')}::jsonb)")

    carga = psql_json(e, f"SELECT ingesta_cargar_tabular({doc},"
                         f" {dolar(json.dumps(filas), 'filas')}::jsonb)")
    psql(e, f"SELECT match_resolver_documento({doc})")
    return doc, ident, carga


def ingerir_compra(e, neg, sesion, ruta):
    """La rama documento de wf_ingesta: el XML se parsea dentro de Postgres."""
    contenido = base64.b64encode(ruta.read_bytes()).decode()
    res = psql_json(e, f"""
      WITH reg AS (SELECT ingesta_registrar_documento(
                     {sesion}, {neg}, {sql_str(ruta.name)}, 'application/xml',
                     decode('{contenido}', 'base64')) AS r)
      SELECT ingesta_procesar_documento(((SELECT r FROM reg) ->> 'documento_id')::bigint)""")
    doc = res.get("documento_id")
    psql(e, f"SELECT match_resolver_documento({doc})")
    return doc, res


# ---------------------------------------------------------------------------
# Totales esperados, calculados del archivo y no de la base
# ---------------------------------------------------------------------------
def total_csv(ruta, mapeo):
    filas, _ = leer_csv(ruta)
    col = (mapeo or {}).get("columnas", {}).get("valor_total", "total")
    dec = (mapeo or {}).get("decimal", ".")
    mil = (mapeo or {}).get("miles", "")
    total = 0.0
    for f in filas:
        v = f[col]
        if mil:
            v = v.replace(mil, "")
        if dec == ",":
            v = v.replace(",", ".")
        total += float(v)
    return round(total), len(filas)


def totales_xml(ruta):
    """Los dos totales de la factura, que NO son el mismo número.

    `movimientos` guarda el valor de línea (base gravable): el
    `LineExtensionAmount` del `LegalMonetaryTotal`. `facturas` guarda lo que hay
    que pagarle al proveedor, IVA incluido: el `PayableAmount`. Comparar los
    movimientos contra el payable daría siempre la diferencia del impuesto, y
    esa confusión es justo la que esta prueba tiene que descartar.
    """
    import re
    t = ruta.read_text()
    base = re.search(r"<cbc:LineExtensionAmount[^>]*>([\d.]+)<", t)
    pagar = re.search(r"<cbc:PayableAmount[^>]*>([\d.]+)<", t)
    return (round(float(base.group(1))) if base else None,
            round(float(pagar.group(1))) if pagar else None)


# ---------------------------------------------------------------------------
# Fases
# ---------------------------------------------------------------------------
def limpiar(e):
    """Borra el negocio de esta prueba y nada más."""
    tablas = ["alertas_enviadas", "recomendaciones", "snapshots_negocio",
              "conocimiento", "conocimiento_pendiente", "conteos_inventario",
              "facturas", "movimientos", "alias", "productos", "terceros",
              "documentos", "ejecuciones", "sesiones", "portal_tokens",
              "identidades", "usuarios"]
    partes = [f"""CREATE TEMP TABLE _u AS
                  SELECT id, negocio_id FROM usuarios WHERE telegram_user_id = {CHAT};"""]
    partes.append("DELETE FROM pagos WHERE factura_id IN (SELECT id FROM facturas"
                  " WHERE negocio_id IN (SELECT negocio_id FROM _u));")
    for t in tablas:
        col = "usuario_id" if t in ("portal_tokens", "identidades") else \
              "id" if t == "usuarios" else "negocio_id"
        origen = "SELECT id FROM _u" if col != "negocio_id" else "SELECT negocio_id FROM _u"
        partes.append(f"DELETE FROM {t} WHERE {col} IN ({origen});")
    partes.append("DELETE FROM negocios WHERE id IN (SELECT negocio_id FROM _u);")

    # Los formatos aprendidos NO son por negocio: el layout que aprende uno lo
    # reconocen todos, y esa es la gracia de la ingesta. Pero si se quedaran, la
    # segunda corrida de esta prueba ya no probaría el aprendizaje, así que se
    # devuelven a como estaban. Solo los inferidos, solo estas huellas, y solo
    # si ningún documento vivo depende de ellos.
    for per in PERIODOS:
        if not per["mapeo"]:
            continue
        _, columnas = leer_csv(HISTORIAL / per["ventas"])
        cols = ",".join(sql_str(c) for c in columnas)
        partes.append(f"""
          DELETE FROM formatos_documento f
           WHERE f.origen = 'inferido'
             AND f.huella = ingesta_huella(ARRAY[{cols}])
             AND NOT EXISTS (SELECT 1 FROM documentos d
                              WHERE d.formato_codigo = f.codigo);""")

    partes.append("SELECT count(*) FROM _u;")
    return psql(e, None, entrada="\n".join(partes))


def fase_alta(e):
    print("\n=== FASE 1 · alta por la ruta real ===", flush=True)
    r = router(e, "/start")
    chk("EMPTY", "alta: /start crea el negocio y saluda",
        "sistema.bienvenida", plantilla(r))
    router(e, "acepto:/start")

    d = psql_json(e, f"""
      SELECT to_jsonb(t) FROM (
        SELECT u.id AS usuario_id, u.negocio_id, n.plan, n.nit,
               u.autorizacion_datos,
               (SELECT count(*) FROM movimientos WHERE negocio_id = u.negocio_id) AS movs,
               (SELECT count(*) FROM productos   WHERE negocio_id = u.negocio_id) AS prods
        FROM usuarios u JOIN negocios n ON n.id = u.negocio_id
        WHERE u.telegram_user_id = {CHAT}) t""")
    chk("EMPTY", "alta: nace en plan free", "free", d["plan"])
    chk("EMPTY", "alta: nace sin NIT", None, d["nit"])
    chk("EMPTY", "alta: autorización registrada", True, d["autorizacion_datos"])
    chk("EMPTY", "alta: cero movimientos", 0, d["movs"])
    chk("EMPTY", "alta: cero productos", 0, d["prods"])

    # Las dos compuertas que un usuario nuevo toca en su primer minuto.
    chk("EMPTY", "consulta sin datos no arranca ejecución", "consulta.sin_datos",
        plantilla(router(e, "¿cuánto vendí este mes?")))
    router(e, "/nueva")
    router(e, "svc:ventas_compras")
    chk("EMPTY", "/listo sin archivos no ejecuta", "sistema.sin_documentos",
        plantilla(router(e, "/listo")))
    chk("EMPTY", "salud sin datos es NULL", None,
        psql_json(e, f"SELECT to_jsonb(salud_negocio({d['negocio_id']}))"))
    router(e, "/cancelar")
    return d["usuario_id"], d["negocio_id"]


def fase_periodo(e, neg, p, n_periodo, con_llm):
    fase = "TRANSICION" if n_periodo == 1 else "CRECIMIENTO"
    print(f"\n=== FASE {n_periodo + 1} · {p['nombre']} ===", flush=True)

    # --- la conversación: elegir servicio y mandar los archivos --------------
    r = router(e, "/nueva")
    r = router(e, "svc:ventas_compras")
    sesion = psql(e, f"SELECT id FROM sesiones WHERE negocio_id = {neg}"
                     f" AND cerrada_en IS NULL ORDER BY id DESC LIMIT 1")
    chk(fase, f"{p['nombre']}: la sesión queda esperando archivos",
        "recibiendo",
        psql(e, f"SELECT estado FROM sesiones WHERE id = {sesion}"))

    # El router es quien decide que un documento entrante se ingiere, y en qué
    # sesión: eso es lo que dispara wf_ingesta en producción.
    r = router(e, "archivo", doc=True)
    chk(fase, f"{p['nombre']}: el documento dispara la ingesta",
        int(sesion), (accion(r, "ingerir") or {}).get("sesion_id"))

    # Compras primero: los productos nacen del EAN de la factura DIAN, y un CSV
    # de ventas cargado antes deja sus filas sin producto y un alias pendiente.
    doc_c, res_c = ingerir_compra(e, neg, sesion, HISTORIAL / p["compra"])
    chk(fase, f"{p['nombre']}: la factura DIAN se parsea",
        "parseado",
        psql(e, f"SELECT estado FROM documentos WHERE id = {doc_c}"))

    doc_v, ident, carga = ingerir_ventas(e, neg, sesion,
                                         HISTORIAL / p["ventas"], p["mapeo"])
    chk(fase, f"{p['nombre']}: {'formato nuevo aprendido' if p['mapeo'] else 'formato reconocido'}",
        bool(p["mapeo"]), bool(ident.get("requiere_inferencia")))
    chk(fase, f"{p['nombre']}: el CSV de ventas se carga", "parseado",
        psql(e, f"SELECT estado FROM documentos WHERE id = {doc_v}"))

    # --- las cifras: contra el archivo, no contra la base -------------------
    esperado_ventas, filas = total_csv(HISTORIAL / p["ventas"], p["mapeo"])
    esperado_compra, esperado_pagar = totales_xml(HISTORIAL / p["compra"])
    real = psql_json(e, f"""
      SELECT to_jsonb(t) FROM (
        SELECT count(*) FILTER (WHERE tipo = 'venta') AS n_venta,
               round(coalesce(sum(valor_total) FILTER (WHERE tipo = 'venta'), 0)) AS venta,
               round(coalesce(sum(valor_total) FILTER (WHERE tipo = 'compra'), 0)) AS compra
        FROM movimientos WHERE negocio_id = {neg}
          AND documento_id IN ({doc_v}, {doc_c})) t""")
    chk(fase, f"{p['nombre']}: filas de venta cargadas", filas, real["n_venta"])
    chk(fase, f"{p['nombre']}: total vendido = el del archivo",
        esperado_ventas, int(real["venta"]))
    chk(fase, f"{p['nombre']}: total comprado = las líneas de la factura",
        esperado_compra, int(real["compra"]))
    chk(fase, f"{p['nombre']}: la cuenta por pagar = el total con IVA",
        esperado_pagar,
        int(float(psql(e, f"SELECT total FROM facturas WHERE documento_id = {doc_c}"))))

    # Matching: que las ventas hayan encontrado el producto que nació de la
    # factura. Es la bisagra entre "hay filas" y "hay análisis posible".
    m = psql_json(e, f"""
      SELECT to_jsonb(t) FROM (
        SELECT (SELECT count(*) FROM productos WHERE negocio_id = {neg}) AS productos,
               (SELECT count(*) FROM movimientos
                 WHERE negocio_id = {neg} AND producto_id IS NULL) AS sin_producto,
               (SELECT count(*) FROM alias
                 WHERE negocio_id = {neg} AND producto_id IS NULL) AS alias_pendientes) t""")
    chk(fase, f"{p['nombre']}: hay productos en el catálogo", True, m["productos"] > 0)
    print(f"      ({m['productos']} productos, {m['sin_producto']} movimientos sin "
          f"resolver, {m['alias_pendientes']} alias pendientes)")

    # --- el análisis --------------------------------------------------------
    r = router(e, "/listo")
    ej = accion(r, "ejecutar")
    chk(fase, f"{p['nombre']}: /listo abre la ejecución", True, ej is not None)
    if ej is None:
        return
    eid = ej["ejecucion_id"]

    if con_llm:
        # `ejecucion_preparar` NO se llama acá: corrido sin datos de entrada, el
        # nodo `Preparar` de wf_ejecutar toma «la última ejecución en
        # preparando», y prepararla antes la sacaría de ese estado dejándole
        # otra al workflow. Prepara él, que es justamente lo que se quiere ver.
        print("      corriendo wf_ejecutar de verdad…", flush=True)
        r8 = subprocess.run(
            ["docker", "compose", "exec", "-e", "N8N_RUNNERS_BROKER_PORT=5699",
             "-T", "n8n", "n8n", "execute", "--id", "wfEjecutar000000001"],
            cwd=RAIZ, capture_output=True, text=True)
        fila = psql_json(e, f"""
          SELECT to_jsonb(t) FROM (SELECT estado::text, error, hallazgos,
                                          tokens_prompt, tokens_salida
                                     FROM ejecuciones WHERE id = {eid}) t""")
        chk(fase, f"{p['nombre']}: wf_ejecutar cierra la ejecución",
            "completada", fila["estado"])
        if fila["estado"] != "completada":
            print((r8.stderr or r8.stdout)[-1200:])
        prep = {"bloqueado": False, "error": fila.get("error"),
                "hallazgos": fila.get("hallazgos")}
        print(f"      ({fila.get('tokens_prompt')} tokens de prompt, "
              f"{fila.get('tokens_salida')} de salida)")
    else:
        prep = psql_json(e, f"SELECT ejecucion_preparar({eid})")

    chk(fase, f"{p['nombre']}: la ejecución no se bloquea", False, prep.get("bloqueado"))
    chk(fase, f"{p['nombre']}: no falla al preparar", None, prep.get("error"))

    h = prep.get("hallazgos") or {}
    chk(fase, f"{p['nombre']}: el análisis ya tiene semáforo", True,
        (h.get("salud") or {}).get("indice") is not None)
    chk(fase, f"{p['nombre']}: el periodo del informe = el de los datos", True,
        (h.get("periodo") or {}).get("desde") is not None)

    if not con_llm:
        # Sin LLM se cierra con el informe seco, que es el que produce
        # `informe_render` y el que entrega producción cuando el modelo no pasa
        # `validar_cifras`. El cierre es el mismo: snapshot + recomendaciones.
        cerr = psql_json(e, f"""
          SELECT ejecucion_cerrar({eid}, 'completada', jsonb_build_object('texto',
            informe_render(
              informe_estructura_seca((SELECT hallazgos FROM ejecuciones WHERE id = {eid}),
                                      'ventas_compras'),
              (SELECT hallazgos FROM ejecuciones WHERE id = {eid}), 'ventas_compras')))""")
        chk(fase, f"{p['nombre']}: el análisis deja snapshot", True,
            cerr.get("snapshot_id") is not None)

    # El informe entregado no puede contener una cifra que no esté en los
    # hallazgos: es la regla R-I, y acá se comprueba sobre el texto real.
    val = psql_json(e, f"""
      SELECT validar_cifras((SELECT texto FROM ejecuciones WHERE id = {eid}),
                            (SELECT hallazgos FROM ejecuciones WHERE id = {eid}))""")
    chk(fase, f"{p['nombre']}: el informe no trae cifras inventadas", True, val["ok"])

    # --- lo que quedó en la memoria ----------------------------------------
    est = psql_json(e, f"""
      SELECT to_jsonb(t) FROM (
        SELECT (SELECT count(*) FROM snapshots_negocio WHERE negocio_id = {neg}) AS snapshots,
               (SELECT count(*) FROM recomendaciones WHERE negocio_id = {neg}) AS recos,
               (SELECT count(*) FROM recomendaciones
                 WHERE negocio_id = {neg} AND estado IN ('nueva','vigente')) AS vigentes) t""")
    print(f"      ({est['snapshots']} snapshots, {est['recos']} recomendaciones, "
          f"{est['vigentes']} vigentes)")

    # Toda recomendación tiene que poder justificarse con un objeto real del
    # negocio: sin esto, «subile el precio» no dice a qué.
    huerfanas = psql(e, f"""
      SELECT count(*) FROM recomendaciones r
       WHERE r.negocio_id = {neg}
         AND r.clave_objeto LIKE 'producto:%'
         AND NOT EXISTS (SELECT 1 FROM productos p
                          WHERE p.negocio_id = {neg}
                            AND p.id = nullif(split_part(r.clave_objeto, ':', 2), '')::bigint)""")
    chk(fase, f"{p['nombre']}: ninguna recomendación apunta a un producto inexistente",
        "0", huerfanas)

    # El reloj del simulador: `snapshot_tomar` graba siempre con `current_date`
    # y hay UNIQUE (negocio_id, fecha). Tres periodos en un minuto serían tres
    # veces la misma fila y no habría contra qué comparar. Es la única escritura
    # de este script que no pasa por una función de Chasqui, y mueve una fecha,
    # no una cifra (mismo compromiso que `bin/cargar_datos_prueba.py`).
    if p["hasta"]:
        psql(e, f"""UPDATE snapshots_negocio SET fecha = '{p['hasta']}'::date
                     WHERE negocio_id = {neg} AND fecha = current_date""")


def fase_plan(e, neg):
    """El periodo que el plan free no lee, y lo que pasa cuando el plan crece."""
    print("\n=== FASE 5 · la ventana del plan ===", flush=True)
    d = psql_json(e, f"""
      SELECT to_jsonb(t) FROM (
        SELECT plan_desde({neg}) AS desde,
               (SELECT count(*) FROM movimientos  WHERE negocio_id = {neg}) AS guardados,
               (SELECT count(*) FROM mov_visibles WHERE negocio_id = {neg}) AS visibles) t""")
    chk("CRECIMIENTO", "en free, mayo se guarda pero no se analiza",
        True, d["guardados"] > d["visibles"])
    print(f"      (ventana free desde {d['desde']}: {d['guardados']} guardados, "
          f"{d['visibles']} visibles)")

    psql(e, f"UPDATE negocios SET plan = 'pro' WHERE id = {neg}")
    d2 = psql_json(e, f"""
      SELECT to_jsonb(t) FROM (
        SELECT (SELECT count(*) FROM movimientos  WHERE negocio_id = {neg}) AS guardados,
               (SELECT count(*) FROM mov_visibles WHERE negocio_id = {neg}) AS visibles) t""")
    chk("CRECIMIENTO", "al ampliar el plan la historia aparece sin recargar nada",
        d2["guardados"], d2["visibles"])


def fase_historia(e, neg):
    print("\n=== FASE 6 · historia y comparativos ===", flush=True)
    comp = psql_json(e, f"SELECT hallazgos_comparativo({neg})")
    chk("CRECIMIENTO", "con dos periodos hay comparativo", True, comp is not None)
    if comp:
        chk("CRECIMIENTO", "el comparativo trae el delta de salud calculado en SQL",
            True, comp.get("salud_delta") is not None)
        print(f"      (salud {comp.get('salud_anterior')} → {comp.get('salud_actual')}, "
              f"delta {comp.get('salud_delta')})")

    perfil = psql_json(e, f"SELECT perfil_negocio({neg})")
    per = perfil.get("periodo") or {}
    chk("CRECIMIENTO", "el perfil cubre los tres periodos", True,
        str(per.get("desde", ""))[:7] <= "2026-05")
    print(f"      (periodo {per.get('desde')} → {per.get('hasta')}, "
          f"{per.get('movimientos')} movimientos)")

    salud = psql_json(e, f"SELECT salud_negocio({neg})")
    chk("CRECIMIENTO", "el índice de salud está en rango", True,
        salud is not None and 0 <= salud["indice"] <= 100)
    print(f"      (salud {json.dumps(salud, ensure_ascii=False)})")

    # Cartera: sin NIT, toda factura DIAN entra como compra. Con el NIT puesto
    # desde el portal, `cartera_refacturar` reclasifica lo ya cargado.
    psql(e, f"""SELECT set_config('request.jwt.claims',
                  jsonb_build_object('negocio_id', {neg})::text, false)""")
    n_fact = psql(e, f"SELECT count(*) FROM facturas WHERE negocio_id = {neg}")
    chk("CRECIMIENTO", "las tres facturas DIAN quedaron en cartera", "3", n_fact)

    # Consulta libre: ahora sí hay números que responder.
    chk("CRECIMIENTO", "con datos, una pregunta ya arranca el análisis",
        "consulta.pensando", plantilla(router(e, "¿cuánto vendí en junio?")))


def informe():
    print("\n" + "=" * 74)
    fases = {}
    for fase, prueba, esp, obt, ok in RESULTADOS:
        fases.setdefault(fase, []).append((prueba, esp, obt, ok))
    for fase, filas in fases.items():
        n_ok = sum(1 for f in filas if f[3])
        print(f"{fase:14s} {n_ok}/{len(filas)} PASS")
        for prueba, esp, obt, ok in filas:
            if not ok:
                print(f"    FALLA  {prueba}: esperado {esp}, obtenido {obt}")
    total = len(RESULTADOS)
    fallas = sum(1 for r in RESULTADOS if not r[4])
    print("=" * 74)
    print(f"{total - fallas}/{total} pruebas pasaron")
    return fallas


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--con-llm", action="store_true",
                   help="corre wf_ejecutar de verdad (gasta tokens)")
    p.add_argument("--limpiar", action="store_true",
                   help="borra el negocio de la prueba y sale")
    p.add_argument("--conservar", action="store_true",
                   help="deja el negocio cargado para inspeccionarlo")
    args = p.parse_args()

    e = env()
    if not HISTORIAL.exists():
        sys.exit(f"no encuentro {HISTORIAL}")

    n = limpiar(e)
    if args.limpiar:
        print(f"borrado: {n} usuario(s) de prueba")
        return 0

    usr, neg = fase_alta(e)
    print(f"    (negocio {neg}, usuario {usr})")
    for i, per in enumerate(PERIODOS, start=1):
        fase_periodo(e, neg, per, i, args.con_llm)
    fase_plan(e, neg)
    fase_historia(e, neg)

    fallas = informe()
    if args.conservar:
        print(f"\nel negocio {neg} queda cargado; para borrarlo: "
              f"python3 bin/prueba_ciclo_vida.py --limpiar")
    else:
        limpiar(e)
        print("\nnegocio de prueba borrado (--conservar para dejarlo)")
    return 1 if fallas else 0


if __name__ == "__main__":
    sys.exit(main())
