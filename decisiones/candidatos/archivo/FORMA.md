# Decisiones de forma — no se congelan

Estas 22 migraciones cambian **cómo se ve y cómo se dice**: textos, plantillas,
prompts, teclados, menús, botones, formato del informe.

**No se convierten en decisiones, a propósito.** Chasqui está justamente en la
fase de pulir la forma para salir a producción: escribir un invariante sobre un
texto o un teclado hoy sería bloquear el trabajo que está en curso, y obligar a
escribir una decisión que superseda a otra cada vez que se cambia una palabra.

La forma se gobierna por el producto y por la prueba de usuario, no por un
invariante. Si alguna de estas terminara siendo estructural —por ejemplo, "un
menú siempre reemplaza al anterior" (070)— se promueve entonces, con la
evidencia de producción que lo justifique.

El razonamiento original de cada una sigue en la cabecera de su migración.

**22 migraciones.** Extraído de `decisiones/candidatos/` el 2026-08-18.

| migración | de qué trata |
|---|---|
| [`003_semillas.sql`](../../docs/historico/migraciones/003_semillas.sql) | semillas de contenido |
| [`007_fix_mapeo_pos.sql`](../../docs/historico/migraciones/007_fix_mapeo_pos.sql) | mapeo POS genérico |
| [`010_prompt_pdf_ventas.sql`](../../docs/historico/migraciones/010_prompt_pdf_ventas.sql) | prompt de ventas_compras |
| [`011_modelo_deepseek_v4.sql`](../../docs/historico/migraciones/011_modelo_deepseek_v4.sql) | renombre de modelos |
| [`013_plantillas_router.sql`](../../docs/historico/migraciones/013_plantillas_router.sql) | textos del router |
| [`018_plantillas_ingesta.sql`](../../docs/historico/migraciones/018_plantillas_ingesta.sql) | mensajes de ingesta |
| [`020_informe_en_chat.sql`](../../docs/historico/migraciones/020_informe_en_chat.sql) | informe como texto en chat |
| [`021_informe_texto_plano.sql`](../../docs/historico/migraciones/021_informe_texto_plano.sql) | informe en texto plano |
| [`022_plantillas_html.sql`](../../docs/historico/migraciones/022_plantillas_html.sql) | mensajes a HTML |
| [`024_router_botones.sql`](../../docs/historico/migraciones/024_router_botones.sql) | conversación a botonazos |
| [`025_informe_estructurado.sql`](../../docs/historico/migraciones/025_informe_estructurado.sql) | informe con forma de ficha |
| [`027_teclado_plano.sql`](../../docs/historico/migraciones/027_teclado_plano.sql) | teclado plano |
| [`028_prompt_cifras_cupo.sql`](../../docs/historico/migraciones/028_prompt_cifras_cupo.sql) | ajustes de prompt |
| [`031_estructura_seca_en_sql.sql`](../../docs/historico/migraciones/031_estructura_seca_en_sql.sql) | estructura seca en SQL |
| [`032_entrega_por_servicio.sql`](../../docs/historico/migraciones/032_entrega_por_servicio.sql) | entrega por servicio |
| [`042_confirmar_carga.sql`](../../docs/historico/migraciones/042_confirmar_carga.sql) | confirmar carga una vez |
| [`045_menu_modulos.sql`](../../docs/historico/migraciones/045_menu_modulos.sql) | primera pantalla: menú de módulos |
| [`046_conversacion_directa.sql`](../../docs/historico/migraciones/046_conversacion_directa.sql) | entrada simplificada |
| [`048_formatos_reales.sql`](../../docs/historico/migraciones/048_formatos_reales.sql) | formatos reales en el mensaje |
| [`049_boton_analizar_en_carga.sql`](../../docs/historico/migraciones/049_boton_analizar_en_carga.sql) | botón analizar en el menú |
| [`052_aviso_ia_en_consulta.sql`](../../docs/historico/migraciones/052_aviso_ia_en_consulta.sql) | aviso de IA en consulta |
| [`070_menus_que_no_saturan.sql`](../../docs/historico/migraciones/070_menus_que_no_saturan.sql) | un menú reemplaza al anterior |
