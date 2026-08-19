# Guía de trabajo — para quien dirige Chasqui

Esta guía es para el humano. La versión para agentes es `AGENTS.md`, en la raíz;
dicen lo mismo pero esta explica el porqué y aquella impone el contrato.

---

## 1. Dónde está cada cosa

Chasqui tiene tres registros distintos y confundirlos es el origen de casi todos
los errores que ha tenido este proyecto.

| Pregunta | Dónde se responde | Qué NO sirve para responderla |
|---|---|---|
| **¿Cómo debe funcionar?** | `decisiones/` · `AGENTS.md` | el código |
| **¿Cómo está implementado hoy?** | `db/actual/` | `db/migraciones/` |
| **¿Por qué llegó a ser así?** | cabecera de la migración · `git log` | la intuición |

La razón de la segunda fila, medida: las 73 migraciones que construyeron Chasqui
eran acumulativas y una función se redefinía muchas veces.
`router_procesar_mensaje` aparecía **15 veces**; 45 funciones al menos dos. Quien
buscara ahí "cómo funciona el router" encontraba 15 versiones y podía leer una
que ya no existe. Eso costó un fix perdido: el `periodo` de
`ingesta_resumen_sesion`, que la 046 agregó con justificación explícita y la 051
borró sin mencionarlo.

**Desde el 2026-08-18 eso está resuelto de raíz.** Las 73 se congelaron en
`db/base/` (Chasqui v0) y se archivaron en `docs/historico/migraciones/`.
`db/migraciones/` arranca de nuevo en la `074` y sólo contiene cambios sobre v0.

---

## 2. La fotografía actual: `db/actual/`

Es el estado **vigente** del esquema, volcado desde el catálogo de Postgres. Una
definición por objeto, la que de verdad está cargada.

```
db/actual/
  INDICE.md              ← empezar por acá
  MANIFIESTO.txt         conteos
  grafo.json             quién llama a quién
  funciones/  160 archivos, uno por función
  vistas/      22
  tablas/      34
  contenido/   12 tablas, 202 filas: textos, botones, umbrales, prompts
```

### Cómo consultarla

```bash
# 1. El panorama: qué existe hoy, por familias, con firma y tipo de retorno
less db/actual/INDICE.md

# 2. Una función concreta, completa
cat db/actual/funciones/router_procesar_mensaje.sql

# 3. Quién llama a una función (grafo de llamadas, hoy con grep)
grep -rl 'hallazgos_generar' db/actual/funciones/

# 4. Qué toca una tabla
grep -rl 'movimientos' db/actual/funciones/ | head -20

# 5. Buscar por concepto
grep -ril 'alerta' db/actual/funciones/
```

`INDICE.md` agrupa las 160 funciones por familia (`portal_*` 32, `ingesta_*` 22,
`router_*` 12, `teclado_*` 8, `carga_*` 7…), con argumentos, tipo de retorno y el
archivo donde vive cada una.

### Cómo se mantiene

```bash
bash bin/gen_estado_sql.sh
```

Se corre **después de cada `bin/migrar.sh`**. Es determinista: regenerarlo dos
veces produce un árbol idéntico byte a byte, así que su `git diff` dice
exactamente qué cambió en el sistema — no qué escribiste, sino qué quedó.

**Nunca se edita a mano.** Es un volcado; cualquier edición se pierde en la
siguiente regeneración y `bin/verificar.sh` la detecta.

### Documentación en prosa, complementaria

| Archivo | Qué es |
|---|---|
| `db/actual/INDICE.md` | la fotografía: qué existe **hoy** |
| `AGENTS.md` | el contrato: restricciones R-I..R-IV, congelados, configuración real, prohibiciones |
| `docs/GUIA_TECNICA.md` | cómo está construido y por qué (tesis, stack, los 7 workflows, operación) |
| `docs/GUIA_FUNCIONAL.md` | qué ve el usuario final |
| `decisiones/INDICE.md` | qué gobierna hoy: 18 decisiones vigentes por dominio |
| `docs/TELEGRAM_UX.md` | decisiones de interfaz, incluidas las descartadas |
| `docs/historico/` | **no gobierna nada**: auditoría de agosto, roadmap ejecutado, prototipo de julio. Sólo para reconstruir un porqué |

Si `GUIA_TECNICA.md` y `db/actual/` se contradicen, **manda `db/actual/`**: uno
es prosa que puede envejecer, el otro es la base. Ya pasó: el ROADMAP viejo
afirmaba que el LLM apuntaba a `opencode.ai/zen/v1` con modelo `hy3-free`, y la
realidad era otro proveedor y otro modelo. Por eso la configuración real vive
ahora en `AGENTS.md` y el ROADMAP viejo quedó archivado.

---

## 3. Antes de pedir cualquier cambio

Cuatro preguntas, en este orden. Si las respondes tú, el agente no las inventa.

1. **¿Qué dominio toca?** (alertas, ingesta, hallazgos, router, portal…)
2. **¿Hay una decisión vigente sobre eso?** → `decisiones/INDICE.md`, o pedirle
   al agente que llame `dominio_contexto("alertas")`
3. **¿Ya se descartó este enfoque antes?** → las decisiones `estado: superada` del
   mismo dominio existen justamente para eso.
4. **¿Esto aumenta el conocimiento del negocio, mejora una recomendación o
   permite ejecutar una decisión?** (R-IV). Si no puedes escribir la
   justificación, la pieza no entra.

---

## 4. Cómo se pide cada tipo de cambio

### 4.1 Función nueva o capacidad nueva

Lo que le dices al agente:

> Dominio: `<x>`. Quiero `<qué>`, porque `<por qué>`.
> Revisa primero las decisiones de ese dominio y dime si algo lo contradice
> antes de escribir código.

Lo que debe pasar:

1. El agente reporta decisiones vigentes y superadas del dominio.
2. Te dice si la solicitud choca con alguna **antes** de proponer.
3. Propone; tú apruebas.
4. Migración nueva `NNN_slug.sql` con cabecera que explique el problema medido.
5. `bash bin/migrar.sh && bash bin/gen_estado_sql.sh && bash bin/verificar.sh`
6. Si cambió la arquitectura o una regla de negocio: decisión nueva en
   `decisiones/`, en el **mismo commit**.

### 4.2 Cambio de comportamiento existente

Igual que lo anterior, más un paso al principio: **qué decisión gobierna hoy ese
comportamiento**. Si la hay y el cambio la contradice, no se toca el código
todavía — primero se escribe la decisión que la supersede:

- la vieja pasa a `estado: superada`, con `superseded_by` y `motivo_reemplazo`;
- la nueva la lista en `supersede`.

La vieja **no se borra**. Su valor es que dentro de tres meses nadie reintente
el camino que ya se cerró.

### 4.3 Bug

Un bug es que el código no hace lo que la decisión dice. Así que:

1. **Reproducir y medir.** Número, no impresión. La convención del proyecto es
   cabecera con "el problema, medido" — la 071 empieza con *"101 archivos
   enviados, 63 ingresados"*.
2. **Decidir de qué tipo es:**
   - el código contradice una decisión vigente → es un bug: se arregla, **sin**
     decisión nueva (la decisión ya existía; el código estaba mal).
   - no hay decisión que gobierne el caso → no es un bug, es una decisión
     faltante: se escribe primero y después se implementa.
3. Migración nueva, desde la `074`. **Nunca se edita una migración aplicada ni
   nada de `db/base/`**: editar el baseline deja las bases existentes en un
   estado distinto del repositorio.
4. `bash bin/pruebas.sh` — y si el bug no lo atrapaba ningún banco, agregar el
   caso al banco correspondiente en `db/pruebas/`.

### 4.4 Cambio en un workflow de n8n

Se edita `bin/gen_wf_*.py` y se regenera. **Nunca el JSON**, ni exportando desde
el editor de n8n: `bin/verificar.sh` lo detecta y el cambio se perdería en la
siguiente generación.

```bash
python3 bin/gen_wf_router.py && bash bin/importar-workflows.sh
```

Y antes de eso, la pregunta de la tesis: *¿esto no debería ser un `INSERT` en
Postgres?* Si para lanzar un servicio nuevo hay que abrir el editor de n8n, el
diseño se rompió.

---

## 5. Qué hacer cuando el agente te contradice

Si el agente responde *"esto contradice ALERTAS-001"*, está funcionando como
debe. Tienes tres salidas:

- **Reformular** — muchas veces la solicitud era compatible y estaba mal dicha.
- **Revocar** — la decisión vieja ya no aplica: se escribe la nueva que la
  supersede y se implementa. Es tu llamada y es legítima.
- **Confirmar la excepción** — decides hacerlo igual. Entonces se registra como
  decisión, no como comentario en el chat. Lo que no puede pasar es que el
  cambio entre sin que quede escrito que revocó algo.

---

## 6. Deuda que aparece de paso

Cuando el agente encuentre algo viejo o feo que **no** es parte de lo que
pediste: va a `decisiones/deuda.md` con fecha y evidencia, y ahí se queda.

Esto es deliberado. El bucle que arruinó sesiones anteriores es:

    analizo → veo algo viejo → decido que está mal → lo cambio
    → rompo una decisión anterior → la próxima sesión lo vuelve a cambiar

Corregir deuda es una tarea que tú priorizas, no un efecto secundario de otra.

---

## 7. Cerrar un cambio

```bash
bash bin/migrar.sh          # aplica lo pendiente
bash bin/gen_estado_sql.sh  # actualiza la fotografía
bash bin/verificar.sh       # el juez: 6 chequeos, sin LLM
git diff db/actual/         # ← la revisión que de verdad importa
```

Ese último diff es el que hay que mirar. Muestra qué quedó en el sistema, no qué
escribiste. Es lo que habría atrapado el fix perdido entre la 046 y la 051.

Forma del commit:

```
<qué cambió, en una línea>

Migración: 074_<slug>.sql
Decisión:  ALERTAS-002 (supersede ALERTAS-001)
Verificación: bin/verificar.sh sin violaciones; 6 bancos verdes
```

### Qué chequea `bin/verificar.sh`

1. `workflows/wf_*.json` reproducibles por sus generadores (detecta edición a mano).
2. `db/actual/` al día con el catálogo (omitido si Postgres está abajo).
3. Ninguna migración commiteada fue modificada.
4. Numeración de migraciones sin huecos.
5. Toda migración ≥015 trae cabecera que explique el porqué.
6. Decisiones coherentes: referencias resueltas, `supersede` sin ciclos, sin
   invariantes duplicados en un dominio, `INDICE.md` al día.
7. Los bancos de `db/pruebas/` pasan.

`bash bin/verificar.sh --rapido` omite el 6 cuando quieres una respuesta
inmediata.

---

## 8. Lo que nunca se hace

- Editar `workflows/*.json` o cualquier cosa bajo `db/actual/`.
- Modificar una migración ya aplicada.
- Cambiar comportamiento de producto con `UPDATE` suelto en vez de migración.
- `docker compose down` o recrear contenedores. Sólo `up -d`.
- Mover a un prompt del LLM una cifra, umbral o regla que hoy calcula Postgres
  (R-I). La dirección permitida es la contraria.
- Explicar una decisión en el chat y dejarla ahí.

---

## 9. Estado de la arquitectura

Construido y funcionando:

- `AGENTS.md` — el contrato, leído por Claude Code, Codex, Cursor y otros.
- `db/actual/` + `bin/gen_estado_sql.sh` — la fotografía, regenerable.
- `bin/verificar.sh` — los invariantes, sin LLM.
- `decisiones/` — la estructura y el esquema; `deuda.md` con D-001 a D-004.

Falta, y hasta entonces los pasos 2 y 3 de la sección 3 se hacen con `grep`:

| Fase | Qué habilita |
|---|---|
| 4-5 | grafo de llamadas real: *"si cambio esto, qué se rompe"* |
| 6-7 | las decisiones pobladas: candidatos extraídos de 73 migraciones y 38 transcripts, promovidos a mano |
| 8 | `dominio_contexto()`: el paso 2 en una sola consulta |
| 10 | hooks: contrato inyectado al arrancar, verificación al cerrar |
