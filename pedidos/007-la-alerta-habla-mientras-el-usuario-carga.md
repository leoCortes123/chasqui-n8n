---
id: P-007
titulo: La alerta habla mientras el usuario todavía carga, y repite lo que el informe va a decir
dominio: alertas
clasificacion: defecto
estado: propuesto
decisiones: [ALERTAS-001, INFORME-001, CORE-003]
decision_nueva: null
migracion: null
abierto: 2026-08-22
cerrado: null
---

## Evidencia

Tercera prueba de usuario, 2026-08-22, negocio 168. Línea de tiempo:

```
12:45:38  el usuario autoriza y abre la sesión 1
12:46-12:51  ingesta de 101 archivos
12:50:55  alerta 1  margen  producto:33  Ron añejo x375ml
12:55:49  alerta 2  margen  producto:32  Aguardiente x375ml
12:56:58  arranca el análisis
12:59:15  informe listo — incluye Ron y Aguardiente
13:00:49  alerta 3  margen  producto:26  Café molido x250g
```

Tres avisos proactivos en diez minutos a un usuario que nunca había recibido un
informe, dos de ellos repetidos textualmente en el informe nueve minutos después,
y todos con las cifras inverosímiles de P-005.

`ALERTAS-001` dice "un aviso por negocio por corrida, nunca una ráfaga" y "no se
avisa sin datos nuevos desde el último análisis". La letra se cumple —uno por
corrida del cron, y había datos nuevos en cada una— y el propósito se rompe: el
usuario recibió una ráfaga repartida en tres corridas mientras estaba mirando
subir sus archivos.

## Causa

Dos huecos distintos:

1. `db/actual/vistas/v_negocios_alertables.sql` dispara con
   `m.ultimo_dato > e.ultimo_analisis`. Durante una carga esa condición es cierta
   **desde el primer archivo** y sigue siéndolo hasta que termina el análisis: el
   negocio queda permanentemente alertable justo en el peor momento. La vista no
   mira si hay una sesión abierta ni una ejecución en curso.
2. `alertas_enviadas` se lee y se escribe únicamente dentro de
   `alertas_evaluar.sql:37,46`. Ni `recomendaciones_negocio` ni `informe_render`
   la consultan, así que el cooldown protege alerta-contra-alerta y nada más: lo
   ya avisado vuelve entero en el informe siguiente.

## Cambio

1. `v_negocios_alertables` excluye al negocio con una sesión sin cerrar o una
   ejecución en curso, y exige `alerta_espera_tras_carga_min` desde el último
   movimiento cargado. Propuesto **30**, parámetro en filas.
2. El informe marca la recomendación ya avisada dentro del cooldown en vez de
   omitirla —`CORE-003`: la recomendación persiste y puede evaluarse después—.
   Plantilla nueva `informe.ya_avisado` ("ya te avisé de esto el DD/MM"),
   resuelta en `informe_render` a partir de `alertas_enviadas`.
3. Este pedido **no** toca las cifras: eso es P-005, y hasta que esté aplicado
   alertar mejor sigue siendo alertar absurdos. Dependencia declarada.

## Tareas

- [ ] confirmar con el humano `alerta_espera_tras_carga_min = 30`, y si la espera
      se cuenta desde el último movimiento o desde el cierre de la sesión
- [ ] migración (número al aprobar): vista, parámetro, plantilla, `informe_render`
- [ ] regenerar: `bash bin/gen_estado_sql.sh`
- [ ] banco nuevo `db/pruebas/alertas_ventana.sql`: sesión abierta ⇒ 0 alertas;
      cerrada hace 5 min ⇒ 0; cerrada hace 40 min ⇒ 1; producto ya alertado ⇒
      aparece marcado en el informe
- [ ] `bash bin/verificar.sh`

## Verificación

Repetir la carga de la prueba: durante la ingesta `alertas_evaluar()` devuelve
cero notificaciones para ese negocio, y el informe posterior sale una sola vez.

## R-IV

Mejora la recomendación: el permiso de hablar primero se gasta una sola vez. Tres
avisos repetidos durante una carga es la forma más rápida de que silencien el bot
y se pierdan todos los avisos futuros, incluidos los buenos.
