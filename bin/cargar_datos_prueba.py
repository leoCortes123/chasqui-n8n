#!/usr/bin/env python3
"""Motor de simulación temporal: mete el dataset generado a Chasqui.

Recorre mes a mes, en orden, cada negocio del manifest y para cada mes hace lo
mismo que haría la vida real:

    ventas del mes   -> ingesta_registrar_documento
                        -> ingesta_identificar_tabular
                        -> ingesta_cargar_tabular
    compras del mes  -> ingesta_registrar_documento
                        -> ingesta_procesar_documento
                          (-> ingesta_parsear_dian -> cartera_facturar_dian)
    resolver         -> match_resolver_documento
    conteos/cartera  -> portal_conteo_guardar / portal_factura_guardar /
                        pago_registrar
    fotografiar      -> snapshot_tomar
    registrar        -> recomendaciones_registrar
    medir            -> recomendaciones_medir

Nada de INSERTs directos en `movimientos`: si mañana cambia la ingesta, esto se
rompe a la vista y no en silencio. Las dos únicas escrituras que no pasan por
una función de Chasqui son la creación del negocio y su usuario (que en
producción hace el bot) y el re-fechado del snapshot, explicado abajo.

    python3 bin/cargar_datos_prueba.py --reset
    python3 bin/cargar_datos_prueba.py --escenario saludable
"""
import argparse
import base64
import csv
import datetime as dt
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from datos_prueba_comun import (  # noqa: E402
    MANIFIESTOS, PREFIJO, env, psql, slug)

CABECERA_VENTAS = ["fecha", "producto", "categoria", "cantidad",
                   "precio_unitario", "total"]


def sql_str(t):
    return "'" + str(t).replace("'", "''") + "'"


def dolar(texto, tag):
    """Cita en dólar: el JSON de las filas lleva comillas de todo tipo."""
    assert f"${tag}$" not in texto, "el contenido choca con la cita en dólar"
    return f"${tag}${texto}${tag}$"


# ---------------------------------------------------------------------------
# Negocio y usuario
# ---------------------------------------------------------------------------
def crear_negocio(e, carga):
    """El negocio nace con plan 'pro' y NIT válido (C2).

    En plan `free` la ventana de análisis son 3 meses y `vs_ano_anterior` es
    imposible; y sin NIT `cartera_facturar_dian` no puede distinguir una venta
    de una compra, así que no habría cuentas por cobrar y `cartera` no
    dispararía nunca.
    """
    n = carga["negocio"]
    sql = f"""
    WITH ins AS (
      INSERT INTO negocios (nombre, nit, plan)
      VALUES ({sql_str(n['nombre'])}, {sql_str(n['nit'])}, 'pro')
      RETURNING id)
    , usr AS (
      INSERT INTO usuarios (negocio_id, telegram_user_id, telegram_chat_id,
                            nombre, rol, autorizacion_datos, autorizacion_fecha)
      SELECT id, {n['chat_id']}, {n['chat_id']}, 'Dueño de prueba', 'dueno',
             true, now() FROM ins
      RETURNING id, negocio_id)
    -- El router no busca al usuario por `usuarios.telegram_user_id` sino por
    -- `identidades`: sin esta fila, un mensaje del bot desde este chat intenta
    -- crear un usuario nuevo y choca contra el índice único. Con ella, el
    -- negocio generado es alcanzable desde Telegram como cualquier otro, que
    -- es lo que permite correr `wf_ejecutar` de verdad sobre él.
    , ident AS (
      INSERT INTO identidades (canal, id_externo, usuario_id, datos)
      SELECT 'telegram', '{n['chat_id']}', id,
             jsonb_build_object('chat_id', '{n['chat_id']}')
      FROM usr
      ON CONFLICT (canal, id_externo) DO NOTHING
      RETURNING usuario_id)
    SELECT id FROM ins;"""
    return int(psql(e, sql))


def borrar_generados(e):
    """Borra SOLO los negocios generados. El resto de la base no se toca."""
    tablas = ["alertas_enviadas", "recomendaciones", "snapshots_negocio",
              "conocimiento", "conteos_inventario", "pagos", "facturas",
              "movimientos", "alias", "productos", "terceros", "documentos",
              "ejecuciones", "sesiones", "usuarios"]
    partes = ["CREATE TEMP TABLE _g AS SELECT id FROM negocios "
              f"WHERE nombre LIKE {sql_str(PREFIJO + '%')};"]
    partes.append("DELETE FROM pagos WHERE factura_id IN "
                  "(SELECT id FROM facturas WHERE negocio_id IN (SELECT id FROM _g));")
    for t in tablas:
        if t == "pagos":
            continue
        partes.append(f"DELETE FROM {t} WHERE negocio_id IN (SELECT id FROM _g);")
    partes.append("DELETE FROM negocios WHERE id IN (SELECT id FROM _g);")
    partes.append("SELECT count(*) FROM _g;")
    return psql(e, None, entrada="\n".join(partes))


# ---------------------------------------------------------------------------
# Un mes
# ---------------------------------------------------------------------------
def bloque_ventas(carpeta, nombre, neg):
    ruta = carpeta / nombre
    with ruta.open(newline="") as f:
        filas = list(csv.DictReader(f))
    contenido = base64.b64encode(ruta.read_bytes()).decode()
    cols = ",".join(f"'{c}'" for c in CABECERA_VENTAS)
    return f"""
DO $chq$
DECLARE v_reg jsonb; v_doc bigint;
BEGIN
    v_reg := ingesta_registrar_documento(NULL, {neg}, {sql_str(nombre)},
               'text/csv', decode('{contenido}', 'base64'));
    v_doc := (v_reg ->> 'documento_id')::bigint;
    PERFORM ingesta_identificar_tabular(v_doc, ARRAY[{cols}]);
    IF (SELECT formato_codigo FROM documentos WHERE id = v_doc) IS NULL THEN
        RAISE EXCEPTION 'huella de cabeceras desconocida en %', {sql_str(nombre)};
    END IF;
    PERFORM ingesta_cargar_tabular(v_doc, {dolar(json.dumps(filas), 'filas')}::jsonb);
    PERFORM match_resolver_documento(v_doc);
END $chq$;"""


def bloque_compra(carpeta, nombre, neg):
    ruta = carpeta / nombre
    contenido = base64.b64encode(ruta.read_bytes()).decode()
    return f"""
DO $chq$
DECLARE v_reg jsonb; v_doc bigint; v_res jsonb;
BEGIN
    v_reg := ingesta_registrar_documento(NULL, {neg}, {sql_str(nombre)},
               'application/xml', decode('{contenido}', 'base64'));
    v_doc := (v_reg ->> 'documento_id')::bigint;
    v_res := ingesta_procesar_documento(v_doc);
    IF (SELECT estado FROM documentos WHERE id = v_doc) = 'error' THEN
        RAISE EXCEPTION 'la factura % quedó en error: %', {sql_str(nombre)},
              (SELECT error FROM documentos WHERE id = v_doc);
    END IF;
    PERFORM match_resolver_documento(v_doc);
END $chq$;"""


def bloque_rechazable(carpeta, nombre, neg):
    """Se espera que la compuerta de calidad lo tumbe: el error es el resultado."""
    ruta = carpeta / nombre
    with ruta.open(newline="") as f:
        filas = list(csv.DictReader(f))
    contenido = base64.b64encode(ruta.read_bytes()).decode()
    cols = ",".join(f"'{c}'" for c in CABECERA_VENTAS)
    return f"""
DO $chq$
DECLARE v_reg jsonb; v_doc bigint;
BEGIN
    v_reg := ingesta_registrar_documento(NULL, {neg}, {sql_str(nombre)},
               'text/csv', decode('{contenido}', 'base64'));
    v_doc := (v_reg ->> 'documento_id')::bigint;
    PERFORM ingesta_identificar_tabular(v_doc, ARRAY[{cols}]);
    PERFORM ingesta_cargar_tabular(v_doc, {dolar(json.dumps(filas), 'filas')}::jsonb);
    IF (SELECT estado FROM documentos WHERE id = v_doc) <> 'error' THEN
        RAISE EXCEPTION 'el archivo % debía rechazarse por la compuerta de '
                        'calidad y entró', {sql_str(nombre)};
    END IF;
END $chq$;"""


def bloque_conteos(conteos, neg, hasta):
    if not conteos:
        return ""
    partes = []
    for c in conteos:
        fecha = f"'{c['fecha']}'::date" if c.get("fecha") else "current_date"
        partes.append(f"""
    SELECT id INTO v_prod FROM productos
     WHERE negocio_id = {neg} AND nombre_canonico = {sql_str(c['producto'])};
    IF v_prod IS NULL THEN
        RAISE EXCEPTION 'no existe el producto % para el conteo',
              {sql_str(c['producto'])};
    END IF;
    v_res := portal_conteo_guardar(v_prod, {c['unidades']}, {fecha});
    IF NOT (v_res ->> 'ok')::boolean THEN
        RAISE EXCEPTION 'conteo rechazado: %', v_res;
    END IF;""")
    return f"""
DO $chq$
DECLARE v_prod bigint; v_res jsonb;
BEGIN
    PERFORM set_config('request.jwt.claims',
                       '{{"negocio_id": {neg}}}', true);
{''.join(partes)}
END $chq$;"""


def bloque_facturas(facturas, neg):
    if not facturas:
        return ""
    partes = []
    for f in facturas:
        partes.append(f"""
    v_res := portal_factura_guardar({sql_str(f['tercero'])}, {f['total']},
               '{f['vencimiento']}'::date, {sql_str(f['numero'])},
               '{f['emision']}'::date, {sql_str(f['nit'])});
    IF NOT (v_res ->> 'ok')::boolean THEN
        RAISE EXCEPTION 'factura rechazada: %', v_res;
    END IF;""")
    return f"""
DO $chq$
DECLARE v_res jsonb;
BEGIN
    PERFORM set_config('request.jwt.claims',
                       '{{"negocio_id": {neg}}}', true);
{''.join(partes)}
END $chq$;"""


def bloque_pagos(pagos, neg):
    if not pagos:
        return ""
    partes = []
    for p in pagos:
        partes.append(f"""
    SELECT id INTO v_fac FROM facturas
     WHERE negocio_id = {neg} AND numero = {sql_str(p['numero'])};
    PERFORM pago_registrar(v_fac, {p['valor']}, '{p['fecha']}'::date,
                           'transferencia', 'portal', NULL);""")
    return f"""
DO $chq$
DECLARE v_fac bigint;
BEGIN
{''.join(partes)}
END $chq$;"""


def bloque_acciones(acciones, neg):
    if not acciones:
        return ""
    partes = []
    for a in acciones:
        partes.append(f"""
    SELECT r.id INTO v_reco FROM recomendaciones r
      JOIN productos p ON p.negocio_id = r.negocio_id
                      AND r.clave_objeto = 'producto:' || p.id
     WHERE r.negocio_id = {neg} AND r.regla = {sql_str(a['regla'])}
       AND p.nombre_canonico = {sql_str(a['producto'])}
       AND r.estado IN ('nueva','vigente')
     ORDER BY r.id LIMIT 1;
    IF v_reco IS NULL THEN
        RAISE EXCEPTION 'no hay recomendación % vigente para % : el escenario '
                        'no está produciendo lo que declara',
              {sql_str(a['regla'])}, {sql_str(a['producto'])};
    END IF;
    SELECT id INTO v_usr FROM usuarios WHERE negocio_id = {neg} ORDER BY id LIMIT 1;
    v_res := recomendacion_accion(v_reco, {neg}, {sql_str(a['accion'])}, v_usr);
    IF NOT (v_res ->> 'ok')::boolean THEN
        RAISE EXCEPTION 'la acción no se aplicó: %', v_res;
    END IF;""")
    return f"""
DO $chq$
DECLARE v_reco bigint; v_usr bigint; v_res jsonb;
BEGIN
{''.join(partes)}
END $chq$;"""


def bloque_snapshot(neg, hasta):
    """Foto del estado ANTES de cargar el mes, re-fechada al cierre anterior.

    El orden importa y no es el obvio. `margen_cae` compara el margen de HOY
    contra los dos últimos snapshots no parciales: si la foto se toma justo
    después de cargar el mes, el margen de hoy es idéntico al del último
    snapshot y la comparación «hoy < anterior < el de antes» no puede cumplirse
    nunca. En la vida real el dueño analiza —y ahí queda la foto— y después
    sube los archivos del mes siguiente. Acá se hace lo mismo: la foto de cada
    mes se toma al empezar el siguiente, con la fecha del cierre que retrata.
    El último mes no lleva foto, a propósito: es el «hoy» contra el que se
    comparan las dos anteriores.

    DISCREPANCIA con el plan (C1): `snapshot_tomar` graba siempre con
    `fecha = current_date` y tiene UNIQUE (negocio_id, fecha). Quince meses
    simulados en una tarde serían quince veces la misma fila, y `margen_cae`
    —que compara los dos últimos snapshots no parciales— nunca podría
    dispararse. La foto la sigue tomando la función real; lo único que hace el
    simulador es mover la fecha al mes que representa, que es el reloj de la
    simulación y no lógica de negocio.
    """
    return f"""
DO $chq$
DECLARE v_snap bigint;
BEGIN
    v_snap := snapshot_tomar({neg}, 'manual');
    IF v_snap IS NOT NULL THEN
        UPDATE snapshots_negocio SET fecha = '{hasta}'::date WHERE id = v_snap;
    END IF;
END $chq$;"""


def sql_mes(carpeta, mes, neg):
    partes = []
    if mes.get("snapshot_hasta"):
        partes.append(bloque_snapshot(neg, mes["snapshot_hasta"]))

    # Compras primero, ventas después: es el orden de la vida real y además el
    # único que resuelve el matching. Los productos nacen del EAN de la factura
    # DIAN; un CSV de ventas cargado antes deja sus filas con `producto_id NULL`
    # y un alias `pendiente` que ya no se arregla solo.
    for c in mes["compras"]:
        partes.append(bloque_compra(carpeta, c, neg))
    for v in mes["ventas"]:
        partes.append(bloque_ventas(carpeta, v, neg))
    for r in mes.get("rechazables", []):
        partes.append(bloque_rechazable(carpeta, r, neg))

    ahora = [c for c in mes["conteos"] if not c.get("despues_de_registrar")]
    despues = [c for c in mes["conteos"] if c.get("despues_de_registrar")]
    pag_ahora = [p for p in mes["pagos"] if not p.get("despues_de_registrar")]
    pag_despues = [p for p in mes["pagos"] if p.get("despues_de_registrar")]

    partes.append(bloque_conteos(ahora, neg, mes["hasta"]))
    partes.append(bloque_facturas(mes["facturas"], neg))
    partes.append(bloque_pagos(pag_ahora, neg))
    partes.append(f"SELECT recomendaciones_registrar({neg});")
    partes.append(bloque_acciones(mes["acciones"], neg))
    partes.append(f"SELECT recomendaciones_medir({neg});")

    # Lo que ocurre DESPUÉS de que la recomendación ya existe: el conteo que
    # contradice la estimación y el cliente que por fin paga. Es la única forma
    # de que la prueba pueda comparar el antes y el después.
    if despues or pag_despues:
        partes.append(bloque_conteos(despues, neg, mes["hasta"]))
        partes.append(bloque_pagos(pag_despues, neg))
        partes.append(f"SELECT recomendaciones_registrar({neg});")
        partes.append(f"SELECT recomendaciones_medir({neg});")

    return "\\set ON_ERROR_STOP on\n" + "\n".join(p for p in partes if p)


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--manifest", type=pathlib.Path,
                   default=MANIFIESTOS / "scenarios.json")
    p.add_argument("--reset", action="store_true",
                   help="borra los negocios 'PRUEBA GEN ' antes de cargar")
    p.add_argument("--escenario", action="append",
                   help="cargar solo estos escenarios (repetible)")
    p.add_argument("--cierre", action="store_true",
                   help="al final corre alertas_evaluar e "
                        "informes_periodicos_disparar")
    args = p.parse_args()

    e = env()
    if not args.manifest.exists():
        sys.exit(f"no encuentro {args.manifest}: corré bin/gen_datos_prueba.py")
    man = json.loads(args.manifest.read_text())

    if args.reset:
        n = borrar_generados(e)
        print(f"reset: {n} negocios generados borrados")

    t0 = dt.datetime.now()
    for esc in man["escenarios"]:
        if args.escenario and esc["escenario"] not in args.escenario:
            continue
        carpeta = args.manifest.parent.parent / slug(esc["escenario"])
        neg = crear_negocio(e, esc["carga"])
        print(f"{esc['negocio']} (id {neg})", flush=True)
        anterior = None
        for mes in esc["carga"]["meses"]:
            mes = dict(mes, snapshot_hasta=anterior)
            anterior = mes["hasta"]
            psql(e, None, entrada=sql_mes(carpeta, mes, neg))
            print(f"    {mes['mes']}  "
                  f"{len(mes['ventas'])} ventas / {len(mes['compras'])} compras"
                  f"{'  +conteo' if mes['conteos'] else ''}"
                  f"{'  +factura' if mes['facturas'] else ''}"
                  f"{'  +pago' if mes['pagos'] else ''}"
                  f"{'  +acción' if mes['acciones'] else ''}", flush=True)
        resumen = psql(e, f"""
            SELECT format('%s movimientos, %s productos, %s terceros, '
                          '%s sin resolver, %s recomendaciones vigentes',
              (SELECT count(*) FROM movimientos WHERE negocio_id = {neg}),
              (SELECT count(*) FROM productos WHERE negocio_id = {neg}),
              (SELECT count(*) FROM terceros WHERE negocio_id = {neg}),
              (SELECT count(*) FROM movimientos
                WHERE negocio_id = {neg} AND producto_id IS NULL),
              (SELECT count(*) FROM recomendaciones
                WHERE negocio_id = {neg} AND estado IN ('nueva','vigente')))""")
        print(f"    => {resumen}")

    if args.cierre:
        print("\ncierre del recorrido:")
        print("  alertas_evaluar:", psql(e, "SELECT alertas_evaluar()::text"))
        print("  informes_periodicos_disparar:",
              psql(e, "SELECT informes_periodicos_disparar()::text"))

    print(f"\nlisto en {(dt.datetime.now() - t0).seconds}s")


if __name__ == "__main__":
    main()
