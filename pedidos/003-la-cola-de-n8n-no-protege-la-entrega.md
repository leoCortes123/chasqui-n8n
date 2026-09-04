---
id: P-003
titulo: Una entrega ya encolada muere de hambre cuando el diagnóstico ocupa las cinco ranuras
dominio: proactividad
clasificacion: defecto
estado: propuesto
decisiones: [CONTENIDO-001, CORE-004, ALERTAS-001]
decision_nueva: null
migracion: null
abierto: 2026-08-22
cerrado: null
---

## Evidencia

Tercera prueba de usuario, 2026-08-22, negocio 168, usuario 159, sesión 1,
ejecución 1. La ejecución terminó bien:

```
ejecuciones: id 1, estado 'completada', 12:56:58 → 12:59:15, 13.361 + 1.052 tokens
             texto de 3.411 caracteres
```

El usuario no recibió nada. En la base de n8n:

```
5359  wf_enviar  running  13:01:31   (el informe, chat 8795575758)
5366  wf_enviar  running  13:01:49   (la alerta de margen, mismo chat)
```

Doce minutos después seguían en `running` sin haber arrancado, con 115
ejecuciones en la misma cola —100 de ellas `wf_error` del bucle de P-002— y
`N8N_CONCURRENCY_PRODUCTION_LIMIT: "5"`.

Lo que se esperaba, por `ALERTAS-001` y por el contrato de `wf_enviar`
(`bin/gen_wf_enviar.py:12`, "un mensaje que no llega es un fallo real y tiene que
verse"): o el mensaje sale, o hay una falla que lo diga. Lo que se vio: ni una
cosa ni la otra. La entrega no falló, se quedó sin turno, y nada en la base
registra que un informe generado no llegó nunca.

## Causa

Cuatro mecanismos independientes, ninguno de ellos el bucle de P-002:

1. `bin/gen_wf_enviar.py:139,213` — `retryOnFail: True, maxTries: 3,
   waitBetweenTries: 2000` en `EnviarTexto{0..6}`. Un `403` es permanente y
   consume igual los tres intentos: ~6 s de ranura por falla, siempre en vano.
   La clasificación `transitoria` de `wf_error` existe (`bin/gen_wf_error.py:20`)
   pero no gobierna ningún reintento: se escribe en `fallas` y nadie la lee.
2. Cada falla cuesta **dos** ejecuciones de producción, no una: la de `wf_error`
   y la de su `AvisarAdmin`, que llama a `wf_enviar` como subworkflow.
3. `docker-compose.yml:68` — `EXECUTIONS_TIMEOUT: "300"` cuenta desde que la
   ejecución arranca. Una encolada no expira: espera para siempre.
4. No hay ninguna separación entre el tráfico de servicio (lo que el usuario
   pidió) y el de diagnóstico (los avisos de falla). Compiten por las mismas
   cinco ranuras y el diagnóstico gana por volumen, porque se genera solo.

Con eso, cualquier ráfaga —101 documentos, un proveedor caído, un pico de cron—
reproduce el mismo hambre sin que haya ningún bucle. P-002 apaga el generador de
ráfagas; este pedido arregla lo que hace que una ráfaga se lleve puesta la
entrega del usuario.

## Cambio

Nada de SQL de producto: son los generadores y el compose.

1. **El reintento deja de aplicar a lo permanente.** En `bin/gen_wf_enviar.py`,
   `EnviarTexto*` baja a `maxTries: 1`; el hipo real de red ya lo cubre el
   reintento del nodo HTTP en los canales que lo tienen. Un `403`, un `400` o un
   chat inexistente fallan a la primera y liberan la ranura.
2. **El aviso de falla deja de costar una ejecución por falla.** En
   `bin/gen_wf_error.py`, `AvisarAdmin` sale una vez por ventana de cooldown —
   que es exactamente el parámetro `falla_aviso_cooldown_min` que introduce
   P-002— y no una vez por cada `fallas` insertada. Sin el cooldown de P-002
   este punto no se puede escribir: dependencia declarada.
3. **Más ranuras, y un piso medido.** Subir `N8N_CONCURRENCY_PRODUCTION_LIMIT` en
   `docker-compose.yml` al valor que el host aguante (a decidir con el humano:
   la caja tiene que sostenerlo con la ingesta de 100 archivos en vuelo).
4. **La cola se ve desde la base.** Vista `v_cola_atascada`, hermana de
   `v_ejecuciones_fallidas` y `v_sesiones_atascadas`: una ejecución de Chasqui
   `completada` cuya notificación no salió en N minutos es un hecho que hoy sólo
   se puede averiguar entrando a la base de n8n.

## Tareas

- [ ] decidir con el humano el valor de `N8N_CONCURRENCY_PRODUCTION_LIMIT` y si
      el punto 4 entra en este pedido o se separa
- [ ] `bin/gen_wf_enviar.py`: `maxTries: 1` en `EnviarTexto*`
- [ ] `bin/gen_wf_error.py`: `AvisarAdmin` agrupado por la ventana de cooldown de P-002
- [ ] `docker-compose.yml`: nuevo límite de concurrencia
- [ ] migración de la vista `v_cola_atascada` (número al aprobar), si el punto 4 entra
- [ ] regenerar: `python3 bin/gen_wf_enviar.py && python3 bin/gen_wf_error.py && bash bin/importar-workflows.sh`
- [ ] regenerar: `bash bin/gen_estado_sql.sh` (si entra la vista)
- [ ] `bash bin/verificar.sh`
- [ ] prueba manual: 20 envíos a un chat cerrado en paralelo con una entrega real
      encolada detrás; la entrega sale en menos de 60 s

## Verificación

`select count(*) from execution_entity where status='running'` no pasa del límite
de concurrencia durante la ráfaga, y la entrega de prueba llega al chat.

## R-IV

Permite ejecutar: un informe que se calculó bien y no llegó es trabajo tirado y
un usuario que concluye que Chasqui no funciona. Sin esto no hay forma de saber,
desde la base, que eso pasó.
