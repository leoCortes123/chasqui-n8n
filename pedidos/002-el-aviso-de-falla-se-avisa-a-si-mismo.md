---
id: P-002
titulo: El aviso de falla viaja por el mismo canal que falló, y un 403 se vuelve un bucle
dominio: proactividad
clasificacion: defecto
estado: propuesto
decisiones: [ALERTAS-001, CONTENIDO-001]
decision_nueva: null
migracion: null
abierto: 2026-08-22
cerrado: null
---

## Evidencia

Base limpia (0 documentos, 0 movimientos, 0 sesiones) y aun así:

```
select date_trunc('minute',creada_en), count(*) from fallas group by 1 order by 1 desc;
 2026-08-22 12:27 |  3
 2026-08-22 12:26 |  7
 2026-08-22 12:25 | 10
 2026-08-22 12:24 | 11
 2026-08-22 12:23 |  8

 workflow  |    tipo    | transitoria | count
 wf_enviar | permanente | f           |  109
```

**109 fallas en doce minutos, ~10 por minuto, con la base vacía.** Todas del
mismo nodo de `wf_enviar` y el mismo mensaje: `Forbidden - perhaps check your
credentials?`, que es lo que devuelve Telegram cuando el usuario cerró el chat
con el bot.

## Causa

El circuito se cierra sobre sí mismo:

1. un envío falla en `wf_enviar` con `403` (chat cerrado);
2. `wf_error` registra la falla y **avisa a los admins**
   (`bin/gen_wf_error.py:44` → `SELECT ... FROM usuarios WHERE rol='admin'`);
3. ese aviso sale por `wf_enviar`, al chat del admin;
4. es el mismo chat cerrado → `403` → vuelve al paso 1.

Antes del 2026-08-22 el bucle no podía cerrarse porque **no había ningún admin**
con `telegram_chat_id`: el camino de error no avisaba a nadie (A-05 de la orden
de trabajo del 2026-08-19). Al poner al usuario 52 como admin —necesario para
probar el camino de error— el circuito quedó completo y empezó a girar.

Hay dos defectos, no uno:

- **el aviso de una falla de envío viaja por el mismo canal que acaba de
  fallar**, sin ninguna barrera;
- una falla clasificada `transitoria = f` (**permanente**) se reintenta igual.
  Un `403` de Telegram no mejora con el tiempo: o el chat se abre, o no.

## Cambio

Propuesta, a discutir antes de escribirla:

1. **Cortar la realimentación**: una falla cuyo origen es `wf_enviar` no dispara
   aviso por `wf_enviar` al mismo `chat_id`. Es una condición en la consulta de
   `Admins`, no lógica nueva en un nodo (`CONTENIDO-001`).
2. **Marcar la identidad inalcanzable**: ante un `403`, anotar en `identidades`
   que ese chat no acepta mensajes y dejar de intentar hasta que el usuario
   vuelva a escribir. Telegram sólo se reabre desde el lado del usuario.
3. **Techo de fallas idénticas**: la misma falla permanente, del mismo workflow y
   con el mismo mensaje, se cuenta pero no se vuelve a avisar dentro de un
   cooldown en filas — la misma forma que ya usa `ALERTAS-001` para los avisos de
   negocio.

## Tareas

- [ ] decidir el alcance con el humano (los tres puntos, o sólo el 1 y el 2)
- [ ] migración `077`: consulta de admins con la barrera, marca de identidad inalcanzable, parámetro de cooldown
- [ ] caso en `db/pruebas/router_casos.sql` o banco nuevo: un `403` no genera un segundo aviso
- [ ] `bash bin/verificar.sh`
- [ ] regenerar: `bin/gen_estado_sql.sh`

## R-IV

Permite ejecutar y medir: sin esto, el primer error real de una prueba de usuario
se convierte en un bucle que llena `fallas` a diez filas por minuto y tapa
exactamente la evidencia que la prueba tenía que producir.
