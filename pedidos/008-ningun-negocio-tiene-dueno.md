---
id: P-008
titulo: Ningún negocio tiene dueño y la plataforma no tiene admin, así que el aviso de falla no tiene destinatario
dominio: core
clasificacion: defecto
estado: propuesto
decisiones: [PLANES-001, CONTENIDO-001, PORTAL-001, BASE-001]
decision_nueva: null
migracion: null
abierto: 2026-08-22
cerrado: null
---

## Evidencia

Tercera prueba de usuario, 2026-08-22. El usuario nuevo quedó así:

```
usuarios: id 159, negocio_id 168, rol 'operador'
```

Es el único usuario de su negocio, el negocio se creó para él, y no es su dueño.
El enum `rol_usuario` tiene `dueno | operador | admin` y en toda la base no hay
un solo `dueno` ni un solo `admin` que no se haya puesto a mano.

Consecuencia medida: la consulta `Admins` de `wf_error`
(`bin/gen_wf_error.py:54`, `WHERE rol='admin' AND telegram_chat_id IS NOT NULL`)
devuelve cero filas. Las 2.845 fallas del 2026-08-22 quedaron registradas en la
tabla y **nadie recibió aviso de ninguna**. Es la misma condición que, invertida
a mano el 2026-08-19 para poder probar el camino de error, abrió el bucle de
P-002: hoy el sistema está en uno de los dos extremos, aviso a nadie o aviso
infinito, y no hay un estado intermedio.

`PLANES-001` dice "un usuario nuevo recibe su negocio automáticamente; nadie
queda sin poder cargar". Se cumple. Lo que no existe es la contraparte: recibir
un negocio y no ser su dueño deja al rol sin ningún significado.

## Causa

`db/actual/funciones/usuario_de_canal.sql` inserta en `usuarios` sin especificar
rol, así que aplica el default de la tabla (`db/actual/tablas/usuarios.sql:9`,
`rol DEFAULT 'operador'`). Cuando además crea el negocio para ese usuario, no
vuelve sobre el rol. Ninguna otra ruta de producción escribe `rol`: los únicos
`SET rol` del repo están en `db/pruebas/router_casos.sql:142,149`.

## Cambio

Separar dos cosas que hoy se confunden en un mismo enum mal poblado:

1. **Dueño del negocio.** El usuario para el que `usuario_de_canal` crea el
   negocio queda `rol = 'dueno'`. No es una promoción, es un hecho: es el único
   que hay y el negocio existe por él. Los que se sumen después siguen siendo
   `operador`.
2. **Admin de plataforma.** No puede salir de un chat de Telegram cualquiera. Se
   define en filas de configuración de la instalación, no en `db/base/`
   (`BASE-001`: el baseline no describe la instalación donde se generó), y la
   consulta `Admins` de `wf_error` lee de ahí **más** la barrera de P-002 (no
   avisar por el canal que acaba de fallar, no avisar a un chat marcado
   inalcanzable).
3. Decidir con el humano dónde viven esos ids: parámetro `admins_telegram_ids`
   —respeta `CONTENIDO-001` pero mete identificadores de personas en
   `parametros`, que se vuelca a `db/actual/contenido/`— o un `UPDATE` de
   instalación documentado en la guía. Hay tensión entre `CONTENIDO-001` y
   `BASE-001` y hay que resolverla antes de escribir la migración.

**Bloqueado por P-002 y P-003.** Darle un destinatario a los avisos de falla
antes de que exista la barrera y el corte de reintentos es reabrir el bucle a
propósito. Este pedido no pasa a `aprobado` hasta que los dos estén `aplicado`.

## Tareas

- [ ] resolver con el humano dónde se declara el admin de plataforma (parámetro
      vs. UPDATE de instalación), citando la tensión CONTENIDO-001 / BASE-001
- [ ] verificar que P-002 y P-003 estén `aplicado`
- [ ] migración (número al aprobar): `usuario_de_canal` marca `dueno` al crear el
      negocio; fuente del admin de plataforma
- [ ] `bin/gen_wf_error.py`: `Admins` lee la fuente nueva y respeta la barrera
- [ ] regenerar: `python3 bin/gen_wf_error.py && bash bin/importar-workflows.sh`
- [ ] regenerar: `bash bin/gen_estado_sql.sh`
- [ ] caso en `db/pruebas/router_casos.sql`: usuario nuevo por Telegram ⇒
      `rol='dueno'` con negocio propio; sin admin declarado ⇒ `Admins` devuelve
      cero filas sin romper nada
- [ ] no-regresión del bucle: un 403 sobre el chat del admin produce una falla
      avisada y no una cascada
- [ ] `bash bin/verificar.sh`

## Verificación

Un usuario nuevo por Telegram queda `dueno` de su negocio, y una falla provocada
a propósito llega al admin declarado una sola vez.

## R-IV

Permite ejecutar y medir: sin destinatario, cada falla de producción es un árbol
que cae en el bosque. Con esta prueba se perdieron 2.845 y nadie se enteró hasta
que alguien miró la tabla a mano.
