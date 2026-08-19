# Roadmap — qué falta

Corto a propósito. Lo cerrado está en `docs/historico/AUDITORIA_2026-08.md`; las
restricciones que gobiernan cualquier cosa que entre acá están en `AGENTS.md` y
en `decisiones/`.

**Última actualización: 2026-08-19.**

---

## Cerrado

**Producto.** El roadmap A1..F2 está completo: 17 fases, migraciones 053-069.
Después entraron tres correcciones nacidas de pruebas de usuario —`071` carga sin
pérdida, `072` el informe declara su base, `073` ingesta sin modelo— y hoy son
decisiones vigentes (`INGESTA-002`, `INFORME-001`, `INGESTA-001`).

**Arquitectura de conocimiento.** Las 10 fases están cerradas: `AGENTS.md`,
`db/actual/` + `bin/gen_estado_sql.sh`, `bin/verificar.sh` con 9 chequeos,
el grafo desde `pg_proc.prosrc` (232 aristas), `decisiones/` con 18 decisiones
vigentes, `bin/mcp_decisiones.py` y los 3 hooks.

**Chasqui v0.** Congelado en `db/base/` el 2026-08-18 e **instalado el
2026-08-19**: la base de esta máquina es v0 limpio, sin datos de negocio, con las
73 selladas más la `074`. Las 73 están archivadas en `docs/historico/migraciones/`.

**Candidatos.** Los 18 de `por_promover/` se revisaron y cerraron: 9 decisiones
nuevas y trazabilidad en `decisiones/candidatos/archivo/promovidos/INDICE.md`.

---

## Abierto

### 1. Pruebas de usuario sobre v0

Es lo que está en curso y para lo que se dejó la base limpia. Cómo se arranca
está en el README, sección *Arrancar una prueba de usuario*. Lo que salga de ahí
entra como migración `075` en adelante, con su decisión si cambia una regla.

### 2. WhatsApp — esperando credenciales de Meta

El canal está implementado sobre el mismo router (`CONTENIDO-001`). Pendientes en
`docs/WHATSAPP.md`: verificar la firma `X-Hub-Signature-256` del webhook,
*message templates* para notificaciones proactivas, y vigilar el cobro por
conversación cuando haya volumen.

### 3. Deuda registrada

Nueve entradas en `decisiones/deuda.md`; D-001 y D-004 cerradas. Las abiertas que
más pesan:

- **D-007** dónde vive el nombre del modelo: hoy es entorno horneado en una fila
  de producto, y el DEFAULT de la columna apunta a un modelo que este proxy no
  tiene.
- **D-009** el escenario `datos_incompletos` no dispara `agota` ni `cartera`: hay
  que decidir si miente el generador o el contrato del banco.

Corregirlas es una tarea que se prioriza, no un efecto secundario de otra.

---

## Cómo entra algo nuevo acá

Toda pieza nueva tiene que poder responder R-IV (`AGENTS.md`):

> ¿Esta pieza hace que Chasqui entienda mejor el negocio, recomiende algo mejor
> o permita ejecutar una decisión?

Si no se puede escribir la justificación, no entra. Y si contradice una decisión
vigente de `decisiones/`, primero se escribe la decisión que la supersede.
