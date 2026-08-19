# Las 73 migraciones que construyeron Chasqui v0

> **Documento histórico. No gobierna nada y no se aplica.**
>
> Estas migraciones se ejecutaron entre julio y agosto de 2026 y su resultado
> está congelado en `db/base/`. Se conservan porque explican **por qué** el
> sistema quedó como quedó: cada cabecera trae el problema medido y lo que se
> descartó.
>
> No se leen para saber cómo funciona algo — eso es `db/actual/INDICE.md` — ni
> para saber qué está permitido — eso es `decisiones/`.

## Por qué se archivaron

El proyecto pasó por varias reestructuraciones sin un orden previo, así que las
migraciones se acumularon en capas: **73 archivos, 23.833 líneas, 263
definiciones de función para 163 nombres**. `router_procesar_mensaje` se
redefinió 15 veces y 45 funciones al menos una. Leer eso para entender el
sistema era leer todas las versiones que tuvo, no la que es — y ya costó un fix
perdido: el `periodo` de `ingesta_resumen_sesion`, que la 046 agregó con
justificación explícita y la 051 borró sin mencionarlo.

El esquema real cabe en 9.750 líneas: menos de la mitad.

Antes de archivarlas se extrajo lo que gobierna: 7 decisiones en `decisiones/`,
16 candidatos en `decisiones/candidatos/por_promover/`, y el resto triado en
`decisiones/candidatos/archivo/`.

## Índice

| # | migración | de qué trataba |
|---|---|---|
| 001 | `001_nucleo.sql` | tablas de negocio. |
| 002 | `002_contenido.sql` | el comportamiento como datos. |
| 003 | `003_semillas.sql` | contenido base del sistema (no datos de cliente). |
| 004 | `004_ingesta.sql` | registro y parseo de documentos. |
| 005 | `005_matching.sql` | resolver el texto libre de una línea a un producto canónico. |
| 006 | `006_calculos.sql` | la aritmética vive en vistas, no en plpgsql. |
| 007 | `007_fix_mapeo_pos.sql` | corrige el mapeo del POS genérico. |
| 008 | `008_ejecucion_operacion.sql` | el motor genérico de ejecución, la validación |
| 009 | `009_fix_validar_cifras.sql` | recorta la puntuación final del número antes |
| 010 | `010_prompt_pdf_ventas.sql` | contenido del servicio ventas_compras: |
| 011 | `011_modelo_deepseek_v4.sql` | 011_modelo_deepseek_v4.sql — DeepSeek renombró sus modelos. |
| 012 | `012_router.sql` | el cerebro de la conversación y el resolvedor de plantillas. |
| 013 | `013_plantillas_router.sql` | textos que usa router_procesar_mensaje. |
| 014 | `014_mantenimiento_notif.sql` | el reaper devuelve notificaciones listas para |
| 015 | `015_router_admin.sql` | comandos de operación dentro de la misma máquina de |
| 016 | `016_fix_jsonb_literales.sql` | corrige tipado de los literales JSON en el |
| 017 | `017_ingesta_tabular.sql` | la ingesta tabular deja de asumir un esquema fijo. |
| 018 | `018_plantillas_ingesta.sql` | el mensaje deja de ser "está mal y ya". |
| 019 | `019_ingesta_encadenado.sql` | dos arreglos que salen de encadenar la ingesta |
| 020 | `020_informe_en_chat.sql` | el informe se entrega como texto en el chat, no como PDF. |
| 021 | `021_informe_texto_plano.sql` | el informe se lee en el chat, así que se escribe |
| 022 | `022_plantillas_html.sql` | los mensajes pasan a HTML y las variables se escapan. |
| 023 | `023_teclados.sql` | los botones también son filas, no nodos. |
| 024 | `024_router_botones.sql` | la conversación se maneja a botonazos. |
| 025 | `025_informe_estructurado.sql` | el informe se ve como una ficha, no como un |
| 026 | `026_fix_cifras_miles.sql` | validar_cifras entendía mal los separadores de miles. |
| 027 | `027_teclado_plano.sql` | el teclado se aplana a un botón por fila y con tope. |
| 028 | `028_prompt_cifras_cupo.sql` | dos ajustes que salieron de la primera corrida |
| 029 | `029_servicios_identidades_conocimiento.sql` | los tres cimientos de la Fase 1 |
| 030 | `030_servicio_consulta.sql` | "preguntale a tu propio negocio", sin un solo |
| 031 | `031_estructura_seca_en_sql.sql` | el informe seco deja de saber de ventas. |
| 032 | `032_entrega_por_servicio.sql` | el último mensaje y sus botones también los |
| 033 | `033_portal.sql` | la puerta del portal: enlace mágico, JWT y las RPC que el |
| 034 | `034_ejecucion_privada.sql` | ninguna función es pública por defecto. |
| 035 | `035_portal_movimientos.sql` | Fase 2, primer paso: la facturación, en el portal. |
| 036 | `036_cartera.sql` | Fase 2: cartera. Quién me debe, a quién le debo. |
| 037 | `037_portal_cartera.sql` | la cartera, en el portal. |
| 038 | `038_portal_nit.sql` | el NIT del negocio se captura en el portal. |
| 039 | `039_funciones_privadas_de_verdad.sql` | la 034 no cerraba las funciones nuevas. |
| 040 | `040_cotizador.sql` | el cotizador, en el portal (cierra la Fase 2). |
| 041 | `041_cobro.sql` | Fase 3 sin WhatsApp: el cobro, a mano y sin vergüenza. |
| 042 | `042_confirmar_carga.sql` | la carga se confirma una vez, no archivo por archivo. |
| 043 | `043_mercado_compras.sql` | segundo servicio de archivos: informe de compras. |
| 044 | `044_whatsapp.sql` | WhatsApp (Cloud API) como segundo canal sobre el MISMO |
| 045 | `045_menu_modulos.sql` | la primera pantalla deja de vender un análisis y pasa |
| 046 | `046_conversacion_directa.sql` | la entrada se simplifica y la carga de |
| 047 | `047_informe_prescriptivo.sql` | el informe deja de describir y pasa a recetar. |
| 048 | `048_formatos_reales.sql` | el mensaje de carga prometía PDF. |
| 049 | `049_boton_analizar_en_carga.sql` | el botón de analizar vive en el mensaje |
| 050 | `050_negocio_automatico.sql` | un usuario sin negocio no puede cargar nada. |
| 051 | `051_consentimiento_y_plan_free.sql` | el permiso se pide donde se entienden |
| 052 | `052_aviso_ia_en_consulta.sql` | la respuesta del chat también la escribe la IA. |
| 053 | `053_historia_completa.sql` | el plan limita lo que se LEE, nunca lo que se |
| 054 | `054_inventario_declarado.sql` | el stock deja de ser una suposición anónima. |
| 055 | `055_impacto_tipado.sql` | dos defectos que se corrigen juntos porque viven en |
| 056 | `056_router_modular.sql` | se acaban las copias de 300 líneas. |
| 057 | `057_limpieza.sql` | sacar lo muerto de en medio y cerrar la fuga de datos que |
| 058 | `058_snapshot_negocio.sql` | Chasqui empieza a acordarse. |
| 059 | `059_recomendaciones_persistentes.sql` | una recomendación deja de ser un |
| 060 | `060_reglas_comparativas.sql` | Chasqui deja de mirar una foto y mira la |
| 061 | `061_perfil_negocio.sql` | todo lo que Chasqui sabe de un negocio, en un objeto. |
| 062 | `062_consulta_sobre_numeros.sql` | la pregunta insignia del producto empieza a |
| 063 | `063_intenciones_consulta.sql` | preguntar por un número puntual y que el número |
| 064 | `064_acciones.sql` | el ciclo se cierra: una recomendación se puede ejecutar. |
| 065 | `065_pedido.sql` | las recomendaciones de "se agota" se convierten en una lista |
| 066 | `066_resultado.sql` | se cierra la pregunta que ninguna de las fases anteriores |
| 067 | `067_alertas.sql` | Chasqui habla primero. |
| 068 | `068_informe_periodico.sql` | el informe que nadie pidió y todos necesitan. |
| 069 | `069_cartera_liquidez.sql` | la cartera deja de ser una pestaña y pasa a ser una |
| 070 | `070_menus_que_no_saturan.sql` | un menú reemplaza al anterior en vez de |
| 071 | `071_carga_sin_perdida.sql` | ningún archivo que el usuario mande se pierde, |
| 072 | `072_informe_declara_base.sql` | el informe dice de qué datos habla. |
| 073 | `073_ingesta_sin_modelo.sql` | la inferencia de formatos deja de gastar tokens. |
