# Expansión descartada — el futuro, si vuelve

Estas 6 migraciones construyeron la expansión de Chasqui hacia funciones de
ERP: facturación en el portal, cartera como pestaña, captura de NIT, cotizador y
cobro por Wompi.

La reestructuración las descartó. `CORE-004` las congela: no vuelven salvo que se
demuestre que alimentan la capacidad de análisis. La cartera es el caso
interesante — no se descartó del todo: la `069` la reconvirtió en señal de
liquidez, que sí responde "¿dónde estoy perdiendo dinero?". Lo descartado es la
cartera **como funcionalidad de gestión**, no el dato.

**El código sigue vivo en la base.** No se borró nada: está construido y
apagado. Este archivo existe para que, si algún día se retoma, no haya que
reconstruir por qué se hizo y por qué se paró.

Retomarlas exige una decisión nueva que superseda a `CORE-004` para esa pieza.

**6 migraciones.** Extraído de `decisiones/candidatos/` el 2026-08-18.

| migración | de qué trata |
|---|---|
| [`035_portal_movimientos.sql`](../../docs/historico/migraciones/035_portal_movimientos.sql) | facturación en el portal — pieza de expansión ERP |
| [`036_cartera.sql`](../../docs/historico/migraciones/036_cartera.sql) | cartera completa — reconvertida en 069, la versión ERP se descarta |
| [`037_portal_cartera.sql`](../../docs/historico/migraciones/037_portal_cartera.sql) | cartera en el portal — ídem |
| [`038_portal_nit.sql`](../../docs/historico/migraciones/038_portal_nit.sql) | captura de NIT — sólo sirve a facturación |
| [`040_cotizador.sql`](../../docs/historico/migraciones/040_cotizador.sql) | cotizador — congelado en CORE-004 |
| [`041_cobro.sql`](../../docs/historico/migraciones/041_cobro.sql) | cobro Wompi — congelado en CORE-004 |
