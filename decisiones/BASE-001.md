---
id: BASE-001
dominio: base
estado: vigente
fecha: 2026-08-19
titulo: El baseline instala producto, nunca entorno ni lo que el sistema aprendió de un cliente
invariantes:
  - db/base/ no contiene ninguna fila que describa la instalación donde se generó
  - db/base/ no contiene ninguna fila que el sistema haya aprendido de los archivos de un negocio
  - regenerar db/base/ con la base por delante del baseline exige pedir el rebase de forma explícita
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: [CORE-002, PORTAL-001]
implementada_en: [bin/gen_base.sh, bin/verificar.sh]
afecta: [db/base/001_contenido.sql, db/pruebas/empty_state.sql]
procedencia: auditoría del 2026-08-19 sobre la primera instalación desde db/base/
---

## Problema medido

`bin/gen_base.sh` decide qué es producto con un criterio mecánico: una tabla con
columna de pertenencia (`negocio_id`, `usuario_id`, `sesion_id`, `chat_id`) tiene
datos de quien opera la instalación; sin ella, tiene producto. El criterio es
bueno y no alcanza. La primera instalación hecha desde el baseline llevó adentro
dos cosas que ninguna migración puso:

1. **Dos formatos que el sistema aprendió solo.** `formatos_documento` no tiene
   `negocio_id` —un formato aprendido se comparte entre negocios a propósito—,
   así que las filas `tabular_20a6271e84` y `tabular_29ec2affe3` entraron al
   baseline con el mapeo del POS de un cliente, incluido el layout agregado
   `Total_Ventas` que causó el doble conteo que corrigió la 073.

2. **`portal_url_base` con un túnel efímero.** El valor era
   `https://chat-extended-cameras-realize.trycloudflare.com`, el quick tunnel de
   la máquina donde se generó v0. `router_portal` sólo responde `portal.sin_url`
   cuando el valor está **vacío**: con una URL muerta manda el enlace igual, y
   ese enlace lleva el token de sesión del portal en el fragmento. Un quick
   tunnel es un subdominio reciclable, así que la falla no es un enlace roto:
   es entregarle tokens de instalaciones nuevas a quien tome ese subdominio.

Las dos las encontró una persona leyendo el archivo. Nada las habría detectado.

## Decisión

Al baseline entra el producto y nada más. Frente al criterio de la columna de
pertenencia mandan dos preguntas:

- ¿esta fila describe la instalación donde se generó v0? → no entra, o entra
  vacía si el código distingue "sin configurar" de "configurado".
- ¿esta fila la produjo el sistema procesando archivos de un negocio? → no entra,
  aunque la tabla sea de producto.

`formatos_documento` se vuelca filtrado por `origen = 'semilla'`; `parametros`
se vuelca con `portal_url_base` vacío, que es el caso que `router_portal` ya
sabe manejar y que `bin/preparar-portal.sh` llena con `WEBHOOK_URL`.

Como corolario, una prueba no puede dar por sentada una precondición de entorno:
`empty_state` fija la URL del portal y comprueba los dos caminos.

Y regenerar deja de ser rebasar por accidente: si la base tiene migraciones
aplicadas por encima del sello del baseline, `bin/gen_base.sh` aborta y explica
qué absorbería. Rebasar se pide con `--rebasar`.

## Alternativas descartadas

- **Filtrar el volcado de `pg_dump` con grep o awk.** Se intentó: un INSERT de
  `--column-inserts` ocupa varias líneas cuando un valor trae saltos —las
  plantillas los traen— y el filtro por línea partía SQL válido en dos. Los
  INSERT de esas dos tablas se arman con `format()` sobre las columnas del
  catálogo, así que una columna nueva entra sola.
- **Excluir `portal_url_base` del baseline.** La fila desaparecería y
  `bin/preparar-portal.sh`, que hace `UPDATE`, no afectaría ninguna fila: el
  portal quedaría sin forma de configurarse.
- **Confiar en que la persona que genera v0 lo revise.** Es lo que ya falló.
  `bin/verificar.sh` chequeo 8 lo comprueba en cada corrida.

## Consecuencias

Una tabla de producto puede tener filas que no lo son. Cuando aparezca otra
mezcla así, el discriminador se busca en la propia fila (`origen`, `clave`) y se
escribe en `gen_base.sh` con el porqué, no en la cabeza de quien la generó.
