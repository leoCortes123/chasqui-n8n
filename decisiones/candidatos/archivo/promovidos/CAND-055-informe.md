---
id: CAND-055
dominio: informe
estado: candidato
titulo: 055_impacto_tipado.sql — dos defectos que se corrigen juntos porque viven en
invariantes: []          # llenar a mano al promover
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: []
implementada_en: [docs/historico/migraciones/055_impacto_tipado.sql]
afecta:
  - recomendaciones_negocio
  - validar_cifras
procedencia: cabecera de docs/historico/migraciones/055_impacto_tipado.sql, commit 01ad4d8 2026-08-15
---

> **Candidato, no decisión.** Extraído automáticamente el 2026-08-18.
> Nada de acá gobierna hasta que se revise, se le fije estado y se
> mueva a `decisiones/`.

## Cabecera completa, textual

```
055_impacto_tipado.sql — dos defectos que se corrigen juntos porque viven en
la misma frontera: lo que SQL calcula y cómo eso llega al usuario.

-----------------------------------------------------------------------------
DEFECTO 1 (C8/C11) — `validar_cifras` castiga al modelo por copiar bien.
-----------------------------------------------------------------------------
`recomendaciones_negocio` formatea con `fmt_decimal`, que escribe la coma
decimal como se escribe acá: "te alcanza para 142,3 días", "vendés 0,295
unidades por día". Esas frases viajan DENTRO del JSON de hallazgos.

Del lado del texto del modelo el problema ya estaba resuelto: `cifra_variantes`
(026) compara las dos lecturas posibles de un número humano. Pero del lado del
extractor —el conjunto de cifras permitidas— seguía el patrón viejo:

regexp_matches(hallazgos::text, '\d+(?:\.\d+)?')

que parte "142,3" en `142` y `3`. Resultado: el modelo cita fielmente una cifra
que calculó el propio SQL, `validar_cifras` la marca como inventada, se quema
el reintento y el informe termina cayendo al seco.

No es teórico: las dos corridas reales contra el proveedor de LLM terminaron
`completada` pero con el informe seco, rechazando "142,3" y "0,295". Toda la
rama narrada está inutilizada para cualquier negocio cuyo informe incluya
"se agota" o "plata quieta", que es la mayoría.

El arreglo es simétrico al de 026: el extractor también expande cada número de
los hallazgos a sus dos lecturas. Y se hace por UNIÓN con la extracción vieja,
nunca reemplazándola, para que el conjunto permitido sea un SUPERCONJUNTO
estricto del actual: así ninguna cifra que hoy se acepta puede empezar a
rechazarse. Se ensancha lo permitido en el margen tipográfico —"1.234" admite
leerse como 1234 y como 1.234— que es exactamente la ambigüedad que 026 ya
decidió tolerar. Una cifra realmente inventada no coincide con ninguna lectura,
que es lo único que esta validación tiene que atrapar (R-I intacta).

-----------------------------------------------------------------------------
DEFECTO 2 (H4/C5) — `impacto_mes` mezcla flujos con stocks.
-----------------------------------------------------------------------------
Las seis reglas publican su impacto en la misma columna y compiten en el mismo
ranking, pero no miden lo mismo:

R1 costo, R2 proveedor, R3 margen  → pesos POR MES que se van a seguir yendo
R4 se agota                        → pesos UNA VEZ, si se rompe el ciclo
R5 plata quieta                    → un STOCK: capital que ya está inmóvil

Un capital acumulado casi siempre es el número más grande, así que R5 encabeza
el informe por construcción. Con los datos de prueba de este mismo repo:
$386.400 de plata quieta contra un negocio que mueve $264.082 al mes se
clasifica "alta" y sale primero, mientras "te quedás sin producto" queda
tercero. El orden de "¿qué hago primero?" está mal por aritmética, no por
criterio.

QUÉ HACE: `impacto_tipo ∈ {mensual, unico, capital}` en las seis CTEs del
UNION ALL (es posicional: si falta en una, la consulta ni compila), umbrales
propios por tipo, y un orden dentro de cada prioridad por cuántas veces cada
recomendación supera SU PROPIO umbral, no por el tamaño crudo del número.

Lo que NO hace, a propósito: nada de scoring compuesto. Ni confianza, ni
urgencia, ni recurrencia. Solo clasificación y priorización correctas.

=============================================================================
1. Umbrales propios de cada tipo de impacto
=============================================================================
Siguen siendo relativos a lo que el negocio mueve en un mes, igual que
`prioridad_alta_pct` / `prioridad_media_pct` (047), porque $80.000 es enorme
para una tienda y ruido para una distribuidora. Lo que cambia es la vara:

mensual  2% / 0.5%   — se repite todos los meses; poco basta para doler.
unico    10% / 3%    — pasa una vez. Para pesar como una fuga mensual tiene
que ser bastante más grande.
capital  50% / 20%   — es plata que existe, no plata que se pierde: sigue
siendo tuya, solo que quieta. Tener medio mes de
movimiento dormido en mercancía es normal; un mes y
medio, como en el ejemplo de arriba, no.
```
