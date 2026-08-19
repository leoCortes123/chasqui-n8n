#!/usr/bin/env bash
# Materializa en db/actual/ el estado VIGENTE del esquema public de Postgres.
#
# POR QUÉ EXISTE
#
# db/migraciones/ es historia acumulativa: 73 archivos donde una misma función
# se redefine muchas veces (router_procesar_mensaje tiene 15 definiciones, 45
# funciones están redefinidas al menos una vez, 163 nombres reparten 263
# definiciones). Cualquier lector —humano o agente— que busque "cómo está
# implementado X" en db/migraciones/ encuentra varias versiones competidoras y
# puede razonar sobre una que ya no existe. Ese error ya costó un fix perdido:
# el periodo de ingesta_resumen_sesion que la 046 agregó y la 051 borró.
#
# db/actual/ resuelve eso: una definición por objeto, la que de verdad está
# cargada en la base. No reemplaza a las migraciones — siguen siendo la única
# forma de cambiar algo, y el porqué sigue viviendo en sus cabeceras.
# db/actual/ sólo materializa el presente para revisión, para el diff de git y
# para las herramientas de análisis de código.
#
# REGLAS
#
#   - Es generado. Nunca se edita a mano. bin/verificar.sh detecta la edición.
#   - Es determinista: sin timestamps, sin versiones, orden fijo. Regenerarlo
#     dos veces produce árboles idénticos byte a byte.
#   - Se regenera después de cada bin/migrar.sh.
#
# NOMBRES DE ARCHIVO
#
# Un archivo por objeto. Cuando un nombre de función está sobrecargado en la
# base viva (hoy: hallazgos_compras, hallazgos_generar,
# ingesta_identificar_tabular) el archivo lleva además la firma normalizada,
# porque son funciones distintas y deben poder distinguirse.
#
# Ese detalle ya ilustra por qué existe este script: contando sobre los archivos
# de db/migraciones/ salían cinco nombres sobrecargados y ninguno coincidía del
# todo con la realidad — varias de esas firmas viejas ya no existen en la base.
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

DESTINO=db/actual

pg() {
  docker compose exec -T -e PGPASSWORD="$CHASQUI_DB_PASSWORD" postgres \
    psql -v ON_ERROR_STOP=1 -qtAX -U "$CHASQUI_DB_USER" -d "$CHASQUI_DB" "$@"
}

if ! docker compose ps --status running --services 2>/dev/null | grep -qx postgres; then
  echo "ERROR: el servicio postgres no está corriendo. 'docker compose up -d' (nunca down)." >&2
  exit 1
fi

rm -rf "$DESTINO"
mkdir -p "$DESTINO"/funciones "$DESTINO"/vistas "$DESTINO"/tablas

# ── Funciones y procedimientos ────────────────────────────────────────────────
# Se excluyen las que pertenecen a una extensión (pg_depend deptype 'e'): no son
# código del proyecto. \x1f separa campos y \x1e registros, para que un cuerpo
# con saltos de línea no rompa el parseo.
CRUDO=$(mktemp); trap 'rm -f "$CRUDO" "$CRUDO.datos"' EXIT
pg -c "
  SELECT p.proname
      || chr(31) || pg_get_function_identity_arguments(p.oid)
      || chr(31) || (count(*) OVER (PARTITION BY p.proname) > 1)::text
      || chr(31) || pg_get_functiondef(p.oid)
      || chr(30)
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public'
     AND p.prokind IN ('f','p')
     AND NOT EXISTS (SELECT 1 FROM pg_depend d
                      WHERE d.objid = p.oid AND d.deptype = 'e')
   ORDER BY p.proname, pg_get_function_identity_arguments(p.oid)
" > "$CRUDO"

python3 - "$CRUDO" "$DESTINO" <<'PYFUN'
import re, sys, pathlib
crudo   = pathlib.Path(sys.argv[1]).read_text()
destino = pathlib.Path(sys.argv[2])
for registro in crudo.split("\x1e"):
    if not registro.strip():
        continue
    nombre, firma, sobrecargada, cuerpo = registro.strip("\n").split("\x1f", 3)
    if sobrecargada == "true":
        slug = re.sub(r"[^a-z0-9]+", "_", firma.lower()).strip("_") or "sin_args"
        archivo = f"{nombre}__{slug}.sql"
    else:
        archivo = f"{nombre}.sql"
    (destino / "funciones" / archivo).write_text(cuerpo.rstrip("\n") + "\n")
PYFUN

# ── Vistas ───────────────────────────────────────────────────────────────────
for v in $(pg -c "SELECT viewname FROM pg_views WHERE schemaname='public' ORDER BY viewname"); do
  {
    echo "CREATE OR REPLACE VIEW public.$v AS"
    pg -c "SELECT pg_get_viewdef('public.$v'::regclass, true)"
  } > "$DESTINO/vistas/$v.sql"
done

# ── Tablas ───────────────────────────────────────────────────────────────────
# pg_dump reconstruye columnas, constraints, índices y triggers. Se filtran las
# líneas de comentario, SET y SELECT pg_catalog que pg_dump emite con la versión
# del servidor y otros datos de entorno, y las \restrict/\unrestrict que pg_18
# emite con un token ALEATORIO por volcado: no son parte del esquema y romperían
# el determinismo (comprobado: sin este filtro dos volcados seguidos difieren en
# las 34 tablas).
for t in $(pg -c "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename"); do
  docker compose exec -T -e PGPASSWORD="$CHASQUI_DB_PASSWORD" postgres \
    pg_dump -U "$CHASQUI_DB_USER" -d "$CHASQUI_DB" --schema-only --no-owner \
            --no-acl --no-comments -t "public.$t" \
  | grep -vE '^(--|SET |SELECT pg_catalog\.|\\(un)?restrict )' \
  | cat -s > "$DESTINO/tablas/$t.sql"
done

# ── Contenido del sistema ────────────────────────────────────────────────────
# En Chasqui el comportamiento vive en filas: los textos, los botones, los
# umbrales y los prompts son producto, no datos. Se vuelcan acá por la misma
# razón que las funciones: para que el `git diff` muestre el texto que cambió y
# no un INSERT ilegible.
#
# Se cambian por migración, como siempre. Esto es la foto, no la fuente.
#
# Excepción: `portal_url_base` se vuelca VACÍA. Es la URL del quick tunnel del
# momento, que el registrador reescribe en cada reinicio de cloudflared: sin
# neutralizarla, cada `docker compose up` produce un diff en db/actual/ y el
# chequeo 2 de bin/verificar.sh falla por un dato de entorno (`BASE-001`).
mkdir -p "$DESTINO/contenido"
for t in tipos_negocio modulos formatos_documento servicios servicios_entradas \
         sinonimos_columna parametros plantillas prompts prompts_tecnicos \
         intenciones metricas_resultado; do
  docker compose exec -T -e PGPASSWORD="$CHASQUI_DB_PASSWORD" postgres \
    pg_dump -U "$CHASQUI_DB_USER" -d "$CHASQUI_DB" --data-only --no-owner \
            --column-inserts -t "public.$t" \
  | grep -vE '^(--|SET |SELECT pg_catalog\.|\\(un)?restrict )' \
  | sed -E "s|(VALUES \(NULL, 'portal_url_base', )'[^\']*'\);|\\1'\"\"');  -- entorno: la escribe bin/registrar-webhook.sh|" \
  > "$DESTINO/contenido/$t.sql"
done

# ── Índice legible ───────────────────────────────────────────────────────────
# La fotografía del sistema en una página: qué funciones hay, con qué firma y qué
# devuelven, agrupadas por familia. Es lo primero que se lee para saber qué
# existe hoy, sin abrir 216 archivos.
pg -c "
  SELECT 'F' || chr(31) || p.proname
      || chr(31) || pg_get_function_identity_arguments(p.oid)
      || chr(31) || pg_get_function_result(p.oid)
      || chr(31) || (count(*) OVER (PARTITION BY p.proname) > 1)::text
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.prokind IN ('f','p')
     AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid=p.oid AND d.deptype='e')
   ORDER BY p.proname, pg_get_function_identity_arguments(p.oid)
" > "$CRUDO"
pg -c "
  SELECT 'V' || chr(31) || c.relname || chr(31)
      || (SELECT count(*) FROM pg_attribute a
           WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped)::text
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='public' AND c.relkind='v' ORDER BY c.relname
" >> "$CRUDO"
pg -c "
  SELECT 'T' || chr(31) || c.relname || chr(31)
      || (SELECT count(*) FROM pg_attribute a
           WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped)::text
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
   WHERE n.nspname='public' AND c.relkind='r' ORDER BY c.relname
" >> "$CRUDO"

python3 - "$CRUDO" "$DESTINO" <<'PYIDX'
import re, sys, pathlib, collections
crudo   = pathlib.Path(sys.argv[1]).read_text().splitlines()
destino = pathlib.Path(sys.argv[2])

funcs, vistas, tablas = [], [], []
for linea in crudo:
    if not linea.strip():
        continue
    campos = linea.split("\x1f")
    if   campos[0] == "F": funcs.append(campos[1:])
    elif campos[0] == "V": vistas.append(campos[1:])
    elif campos[0] == "T": tablas.append(campos[1:])

familias = collections.defaultdict(list)
for nombre, args, ret, sobrecargada in funcs:
    familias[nombre.split("_")[0]].append((nombre, args, ret, sobrecargada))
grandes = {f: v for f, v in familias.items() if len(v) >= 3}
otras   = sorted((x for f, v in familias.items() if len(v) < 3 for x in v))

def archivo_de(nombre, args, sobrecargada):
    if sobrecargada == "true":
        slug = re.sub(r"[^a-z0-9]+", "_", args.lower()).strip("_") or "sin_args"
        return f"{nombre}__{slug}.sql"
    return f"{nombre}.sql"

sal = ["# Fotografía actual de Chasqui",
       "",
       "Generado por `bin/gen_estado_sql.sh` desde el catálogo vivo de Postgres.",
       "**No editar a mano.** Una entrada por objeto que existe hoy — no hay",
       "versiones históricas acá; para el porqué de cada una, ver su migración.",
       "",
       f"{len(funcs)} funciones · {len(vistas)} vistas · {len(tablas)} tablas",
       ""]

def bloque(titulo, filas):
    sal.append(f"### {titulo}")
    sal.append("")
    sal.append("| función | argumentos | devuelve | archivo |")
    sal.append("|---|---|---|---|")
    for nombre, args, ret, sob in filas:
        a = args if args else "—"
        sal.append(f"| `{nombre}` | `{a}` | `{ret}` | `{archivo_de(nombre, args, sob)}` |")
    sal.append("")

sal.append("## Funciones")
sal.append("")
for familia in sorted(grandes):
    bloque(f"{familia}_*", sorted(grandes[familia]))
if otras:
    bloque("otras", otras)

sal.append("## Vistas")
sal.append("")
sal.append("| vista | columnas |")
sal.append("|---|---|")
for nombre, cols in vistas:
    sal.append(f"| `{nombre}` | {cols} |")
sal.append("")
sal.append("## Tablas")
sal.append("")
sal.append("| tabla | columnas |")
sal.append("|---|---|")
for nombre, cols in tablas:
    sal.append(f"| `{nombre}` | {cols} |")
sal.append("")

(destino / "INDICE.md").write_text("\n".join(sal))
PYIDX

# ── Grafo de llamadas ────────────────────────────────────────────────────────
# POR QUÉ SE GENERA ACÁ Y NO SE DELEGA AL INDEXADOR
#
# codebase-memory-mcp indexa db/actual/ y sí extrae funciones SQL, pero su
# gramática tree-sitter sólo reconoce la llamada en ciertas posiciones. Medido
# el 2026-08-18 sobre este repo: capturó 88 de las 232 aristas reales (38%), y
# de las 7 llamadas de router_procesar_mensaje encontró 2 — se pierden las que
# están en asignación (`v_r := router_h_admin(v_ctx);`), que en PL/pgSQL son la
# mayoría. Un grafo de impacto con 38% de recall es peor que no tenerlo: da
# confianza falsa.
#
# Postgres sí tiene la información: el cuerpo completo está en pg_proc.prosrc.
# El escaneo por nombre con frontera de palabra es exacto para este esquema
# porque no hay sobrecarga de nombres entre esquemas ni funciones homónimas de
# extensiones (se excluyen por pg_depend).
#
# DESPACHO POR FILAS
#
# La tesis de Chasqui es que el comportamiento vive en filas, no en código: un
# servicio declara en `servicios.funcion_hallazgos` qué función lo calcula, y
# ejecucion_preparar la invoca con EXECUTE format('SELECT %I($1,$2)'). Ningún
# analizador estático ve esa arista — ni éste ni codebase-memory-mcp. Sin
# resolverla, hallazgos_generar y hallazgos_compras aparecen como código muerto,
# que es exactamente la conclusión equivocada que lleva a alguien a borrarlas.
# Se resuelve leyendo la tabla, que es donde de verdad está escrito.
#
# Limitación que queda: un EXECUTE cuyo nombre no salga de una columna conocida
# sigue siendo invisible.
# Aristas declaradas en datos: columnas que contienen nombres de función.
pg -c "
  SELECT s.funcion_hallazgos || chr(31) || 'servicios:' || s.codigo
    FROM servicios s WHERE s.funcion_hallazgos IS NOT NULL ORDER BY s.codigo
" > "$CRUDO.datos"

pg -c "
WITH f AS (
  SELECT p.oid, p.proname, p.prosrc, p.proacl
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname='public' AND p.prokind IN ('f','p')
     AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid=p.oid AND d.deptype='e')
), nombres AS (SELECT DISTINCT proname FROM f),
rel AS (SELECT c.relname, c.relkind FROM pg_class c
         JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='public' AND c.relkind IN ('r','v'))
SELECT f.proname
    || chr(31) || coalesce((SELECT string_agg(DISTINCT n.proname, ',' ORDER BY n.proname)
                              FROM nombres n
                             WHERE n.proname <> f.proname
                               AND f.prosrc ~ ('\\m' || n.proname || '\\M[[:space:]]*\\(')), '')
    || chr(31) || coalesce((SELECT string_agg(DISTINCT r.relname, ',' ORDER BY r.relname)
                              FROM rel r
                             WHERE f.prosrc ~ ('\\m' || r.relname || '\\M')), '')
    -- Otras dos formas de entrar que no son una llamada desde SQL:
    -- PostgREST (EXECUTE concedido a un rol que no es el dueño) y triggers.
    || chr(31) || coalesce((SELECT string_agg(DISTINCT 'postgrest:' || a.grantee::regrole::text, ',')
                              FROM aclexplode(f.proacl) a
                             WHERE a.privilege_type='EXECUTE'
                               AND a.grantee <> 0 AND a.grantee <> a.grantor), '')
    || chr(31) || coalesce((SELECT string_agg(DISTINCT 'trigger:' || c.relname, ',' ORDER BY 'trigger:' || c.relname)
                              FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
                             WHERE t.tgfoid = f.oid AND NOT t.tgisinternal), '')
  FROM f GROUP BY f.oid, f.proname, f.prosrc, f.proacl ORDER BY f.proname
" > "$CRUDO"

python3 - "$CRUDO" "$DESTINO" <<'PYGRAFO'
import json, sys, pathlib, collections
crudo   = pathlib.Path(sys.argv[1]).read_text().splitlines()
destino = pathlib.Path(sys.argv[2])

llama_a, usa, entradas = {}, {}, {}
for linea in crudo:
    if not linea.strip():
        continue
    nombre, destinos, tablas, acl, trig = linea.split("\x1f")
    llama_a.setdefault(nombre, set()).update(d for d in destinos.split(",") if d)
    usa.setdefault(nombre, set()).update(t for t in tablas.split(",") if t)
    entradas.setdefault(nombre, set()).update(
        x for x in (acl.split(",") + trig.split(",")) if x)

# Despacho por filas: servicios.funcion_hallazgos -> EXECUTE format(...)
datos = pathlib.Path(sys.argv[1] + ".datos")
if datos.exists():
    for linea in datos.read_text().splitlines():
        if not linea.strip():
            continue
        fn, origen = linea.split("\x1f")
        entradas.setdefault(fn, set()).add(origen)

llamada_por = collections.defaultdict(set)
for origen, destinos in llama_a.items():
    for d in destinos:
        llamada_por[d].add(origen)

# La frontera con n8n: media docena de funciones no las llama ningún SQL sino un
# nodo Postgres de un workflow (hallazgos_generar, mantenimiento_ciclo,
# router_procesar_mensaje...). Sin esto aparecerían como código muerto, que es
# justo la conclusión equivocada que hace que alguien las borre.
import re
raiz = pathlib.Path(".")
desde_wf = collections.defaultdict(set)
for wf in sorted(raiz.glob("workflows/wf_*.json")):
    texto = wf.read_text()
    for nombre in llama_a:
        if re.search(r"\b" + re.escape(nombre) + r"\s*\(", texto):
            desde_wf[nombre].add("n8n:" + wf.name)

grafo = {"_": ("Grafo de llamadas del esquema public, generado por "
               "bin/gen_estado_sql.sh desde pg_proc.prosrc y desde los nodos "
               "Postgres de workflows/wf_*.json. No editar."),
         "funciones": {}}
for nombre in sorted(llama_a):
    grafo["funciones"][nombre] = {
        "llama_a":       sorted(llama_a[nombre]),
        "llamada_por":   sorted(llamada_por.get(nombre, ())),
        "llamada_desde": sorted(desde_wf.get(nombre, set()) | entradas.get(nombre, set())),
        "usa":           sorted(usa[nombre]),
    }
(destino / "grafo.json").write_text(
    json.dumps(grafo, ensure_ascii=False, indent=1, sort_keys=False) + "\n")
aristas = sum(len(v["llama_a"]) for v in grafo["funciones"].values())
puntos = sum(1 for v in grafo["funciones"].values() if v["llamada_desde"])
print(f"grafo.json: {len(grafo['funciones'])} funciones, {aristas} aristas, "
      f"{puntos} con entrada externa (n8n, PostgREST, trigger o fila)")
PYGRAFO

# ── Manifiesto ───────────────────────────────────────────────────────────────
# Sin fecha a propósito: cambia sólo cuando cambia el esquema.
{
  echo "# Estado vigente del esquema public — generado por bin/gen_estado_sql.sh"
  echo "# NO EDITAR A MANO. Se regenera desde el catálogo de Postgres."
  echo "funciones: $(ls "$DESTINO/funciones" | wc -l)"
  echo "vistas:    $(ls "$DESTINO/vistas"    | wc -l)"
  echo "tablas:    $(ls "$DESTINO/tablas"    | wc -l)"
  echo "contenido: $(cat "$DESTINO"/contenido/*.sql | grep -c '^INSERT') filas en $(ls "$DESTINO/contenido" | wc -l) tablas"
} > "$DESTINO/MANIFIESTO.txt"

echo "db/actual/ regenerado:"
sed -n '3,6p' "$DESTINO/MANIFIESTO.txt"
