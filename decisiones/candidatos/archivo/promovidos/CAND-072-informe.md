---
id: CAND-072
dominio: informe
estado: candidato
titulo: 072_informe_declara_base.sql — el informe dice de qué datos habla
invariantes: []          # llenar a mano al promover
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: []
implementada_en: [docs/historico/migraciones/072_informe_declara_base.sql]
afecta:
  - informe_base_bloque
  - informe_render
procedencia: cabecera de docs/historico/migraciones/072_informe_declara_base.sql, commit sin commit (migración aún no versionada)
---

> **Candidato, no decisión.** Extraído automáticamente el 2026-08-18.
> Nada de acá gobierna hasta que se revise, se le fije estado y se
> mueva a `decisiones/`.

## Cabecera completa, textual

```
072_informe_declara_base.sql — el informe dice de qué datos habla.

EL PROBLEMA, MEDIDO EN LA SEGUNDA PRUEBA DE USUARIO

El usuario mandó 101 archivos, entraron 63, y de esos el plan free dejó ver
196 de 380 movimientos. El informe que recibió hablaba de $91.506.262 en
compras. En la carpeta había $612.072.404 entre compras y ventas.

El informe no dijo nada de eso. Su encabezado entero era:

📊 Análisis de ventas y compras
del 2 de junio al 31 de julio de 2026
📦 Productos analizados: 64

El rango es correcto y el conteo también. Pero con esa cabecera no hay forma
de que el usuario detecte que le faltó el 99% de sus datos: no dice cuántos
archivos usó, no dice que hay movimientos guardados fuera de la ventana del
plan, y sobre todo no dice que no tiene UNA SOLA VENTA. El semáforo, encima,
daba 99/100 —porque promedia solo las dimensiones que pudo calcular— así que
todo lo visible apuntaba a que estaba bien.

Un informe que no declara su base no se puede auditar, y uno que no se puede
auditar no se puede creer. Esta migración agrega ese bloque.

POR QUÉ SE CALCULA AL RENDERIZAR Y NO EN hallazgos_generar

Los hallazgos son la entrada del prompt: todo lo que entra ahí el modelo lo
puede citar, y la lista de cifras permitidas de `validar_cifras` crece con
cada número que se agregue. El conteo de archivos no le sirve al modelo para
redactar y sí le daría material para inventar frases sobre la carga. El
bloque es de la base, sale de la base y el modelo no lo ve nunca —mismo
criterio que el encabezado y el semáforo (025, 047)—.

El precio es que se calcula unos segundos después que los hallazgos. Con la
071 esa ventana ya no puede traer archivos nuevos (el análisis no arranca
hasta que haya silencio), así que la diferencia es teórica.

=============================================================================
1. El bloque
=============================================================================
Cuatro cosas, y ninguna es opcional:

* De cuántos archivos salió. Es lo único que el usuario puede comparar
contra lo que mandó, que es toda la certificación que necesita.
* Cuántos movimientos, y de esos cuántos quedaron fuera por el plan.
* Ventas y compras por separado. Cero ventas tiene que gritarlo: la mitad
de las reglas no puede correr sin ellas y el usuario no tiene por qué
saberlo.
* El aviso del NIT, que hasta ahora solo aparecía en el resumen de carga y
se perdía entre 63 mensajes.

`negocio_id` sale de los hallazgos (está ahí desde la 025), así que la función
no necesita más parámetros que los que informe_render ya tiene a mano.
```
