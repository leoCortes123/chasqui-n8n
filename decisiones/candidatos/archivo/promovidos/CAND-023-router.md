---
id: CAND-023
dominio: router
estado: candidato
titulo: 023_teclados.sql — los botones también son filas, no nodos
invariantes: []          # llenar a mano al promover
supersede: []
superseded_by: null
motivo_reemplazo: null
relacionada_con: []
implementada_en: [agent-context/history/migraciones/023_teclados.sql]
afecta:
  - esc_html
  - resolver_plantilla
  - teclado_markup
  - teclado_servicios   # ya no existe en db/actual/
procedencia: cabecera de agent-context/history/migraciones/023_teclados.sql, commit 7eb606e 2026-08-14
---

> **Candidato, no decisión.** Extraído automáticamente el 2026-08-18.
> Nada de acá gobierna hasta que se revise, se le fije estado y se
> mueva a `decisiones/`.

## Cabecera completa, textual

```
023_teclados.sql — los botones también son filas, no nodos.

Objetivo: que el usuario escriba lo mínimo. Cada mensaje del bot puede llevar
su propio teclado inline, y ese teclado se define en la MISMA fila que el
texto. Agregar un botón es un UPDATE, igual que cambiar una palabra.

Forma abstracta (columna plantillas.teclado), no la de Telegram:

[[{"texto":"🚀 Empezar","dato":"/nueva"}],
[{"texto":"❓ Cómo funciona","dato":"/comofunciona"}]]

filas -> botones. `dato` viaja como callback_data; `url` abre un enlace.
Tanto `texto` como `dato` admiten {{variables}}, para teclados con
contenido dinámico (la lista de servicios, por ejemplo).

teclado_markup la traduce a lo que espera la API (`inline_keyboard`), así que
n8n no arma nada: recibe el reply_markup listo y lo pasa. Un teclado vacío
devuelve {"inline_keyboard": []}, que Telegram acepta y muestra sin botones
—a propósito, para no tener que mandar NULL y arriesgar un 400 en el envío.

=== Escape HTML, ahora reutilizable ========================================
Estaba embutido tres veces dentro de resolver_plantilla (migración 022).
```
