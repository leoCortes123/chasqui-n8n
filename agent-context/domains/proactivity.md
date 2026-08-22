---
id: DOMAIN-PROACTIVIDAD
type: domain
status: active
implemented_in: [db/actual/funciones/mantenimiento_ciclo.sql, db/actual/funciones/alertas_evaluar.sql, db/actual/funciones/informes_periodicos_disparar.sql, bin/gen_wf_cron.py]
---

# Proactividad (wf_cron)

**Propósito**: Chasqui habla primero — con límites estrictos para no gastar el
permiso (`ALERTAS-001`).

| | |
|---|---|
| **Entry points** | Schedule 5 min → `SELECT mantenimiento_ciclo()` |
| **Salidas** | notificaciones[] → `wf_enviar` (mode each); ejecuciones[] → `wf_ejecutar` (mode each) |

## Las cuatro cosas que hace `[CONFIRMADO]`

1. **Reaper**: ejecuciones colgadas >15 min → `fallida`, sesión `fallida`,
   aviso `ejecucion.fallida`. Es lo único sin EXCEPTION alrededor.
2. **Expiración**: sesiones >24 h sin actividad → `expirada`; recordatorio único.
3. **Alertas** (`alertas_evaluar`): sólo prioridad alta · un aviso por negocio
   por corrida · cooldown `alerta_cooldown_dias` por (regla, objeto) en
   `alertas_enviadas` · franja horaria del negocio · sólo con datos nuevos desde
   el último análisis. Los cinco límites son parámetros, no constantes.
4. **Informes periódicos** (`informes_periodicos_disparar`): franja 8–20
   America/Bogota; ≥30 días desde último análisis, ≥10 movimientos nuevos,
   ninguna ejecución en vuelo → crea sesión+ejecución y dispara.

Vistas selectoras: `v_negocios_alertables`, `v_negocios_informe_periodico`.

**Decisiones**: `ALERTAS-001`. **Invariantes**: INV-023.

## Trampas

- `alerta_max_por_corrida=1` limita **por corrida**, y hay una corrida cada
  5 minutos: la ráfaga real de la prueba de usuario fue una alerta cada 5 min
  hasta el `Forbidden` del bot bloqueado (A-10/A-12).
- Las dos vistas leen **sólo** `usuarios.telegram_chat_id`: un usuario
  exclusivamente de WhatsApp jamás recibiría alerta ni periódico (DISC-D1).
- `fallas` y `alertas_enviadas` no tienen poda.
