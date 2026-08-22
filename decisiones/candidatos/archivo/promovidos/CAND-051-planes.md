---
id: CAND-051
dominio: planes
estado: candidato
titulo: 051_consentimiento_y_plan_free.sql — el permiso se pide donde se entienden
invariantes: []          # llenar a mano al promover
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: []
implementada_en: [agent-context/history/migraciones/051_consentimiento_y_plan_free.sql]
afecta:
  - ingesta_resumen_sesion
  - movimientos_limite_plan
  - plan_desde
  - router_procesar_mensaje
  - teclado_consentimiento
procedencia: cabecera de agent-context/history/migraciones/051_consentimiento_y_plan_free.sql, commit 7eb606e 2026-08-14
---

> **Candidato, no decisión.** Extraído automáticamente el 2026-08-18.
> Nada de acá gobierna hasta que se revise, se le fije estado y se
> mueva a `decisiones/`.

## Cabecera completa, textual

```
051_consentimiento_y_plan_free.sql — el permiso se pide donde se entienden
sus consecuencias, la IA se declara, y el plan gratis tiene un límite real.

Tres cosas, todas de cara al usuario:

1. CONSENTIMIENTO EN EL MOMENTO CORRECTO. Antes, el primer mensaje que no
fuera /start chocaba contra "necesito tu permiso para tratar los datos de
tu negocio": una frase sola, antes de que el usuario supiera siquiera qué
hace el bot, y al aceptar volvía a la bienvenida perdiendo el paso que
estaba dando. Ahora el menú ("Esto es lo que puedo hacer por ahora") se
puede mirar sin autorizar nada, y el permiso se pide al ELEGIR una opción
—que es cuando de verdad se van a entregar datos—. El botón se lleva
puesto lo que el usuario tocó ('acepto:svc:ventas_compras'), así que al
aceptar el proceso sigue solo, sin repetir el clic.

2. LA IA SE DECLARA. Todo lo que devuelve el asistente sale de un análisis
hecho con IA sobre los archivos del negocio: puede equivocarse, no es
contabilidad certificada y no reemplaza al contador. Eso va en el
consentimiento (antes de aceptar) y al pie de cada informe entregado
(cuando se está leyendo el resultado). En los dos lados, visible.

3. PLAN FREE = 3 MESES DE HISTORIA. Hasta ahora "free" solo limitaba tokens.
El límite de historia se aplica en un trigger sobre `movimientos`: cubre
todos los caminos de carga (XML DIAN, tabular, facturas, cartera) y los
que se agreguen después, sin repetir la regla en cada uno. Lo que queda
fuera de ventana NO se guarda, y se le dice al usuario cuántas filas
fueron y por qué.

=============================================================================
1. Plan free: la ventana de historia
=============================================================================
```
