# Fotografía actual de Chasqui

Generado por `bin/gen_estado_sql.sh` desde el catálogo vivo de Postgres.
**No editar a mano.** Una entrada por objeto que existe hoy — no hay
versiones históricas acá; para el porqué de cada una, ver su migración.

159 funciones · 22 vistas · 34 tablas

## Funciones

### carga_*

| función | argumentos | devuelve | archivo |
|---|---|---|---|
| `carga_arrancar` | `p_sesion_id bigint` | `bigint` | `carga_arrancar.sql` |
| `carga_evaluar` | `p_sesion_id bigint` | `jsonb` | `carga_evaluar.sql` |
| `carga_hay_con_que` | `p_sesion_id bigint` | `boolean` | `carga_hay_con_que.sql` |
| `carga_panel` | `p_sesion_id bigint, p_modo text` | `jsonb` | `carga_panel.sql` |
| `carga_panel_registrar` | `p_sesion_id bigint, p_mensaje_id bigint` | `void` | `carga_panel_registrar.sql` |
| `carga_registrar_fallo` | `p_sesion_id bigint, p_nombre text` | `void` | `carga_registrar_fallo.sql` |
| `carga_resumen` | `p_sesion_id bigint` | `jsonb` | `carga_resumen.sql` |

### conocimiento_*

| función | argumentos | devuelve | archivo |
|---|---|---|---|
| `conocimiento_buscar` | `p_negocio_id bigint, p_texto text, p_limite integer, p_umbral numeric` | `jsonb` | `conocimiento_buscar.sql` |
| `conocimiento_guardar` | `p_negocio_id bigint, p_tipo text, p_titulo text, p_contenido text, p_clave text, p_datos jsonb, p_origen text, p_usuario_id bigint, p_pendiente_id bigint` | `bigint` | `conocimiento_guardar.sql` |
| `conocimiento_pendiente_registrar` | `p_negocio_id bigint, p_pregunta text` | `bigint` | `conocimiento_pendiente_registrar.sql` |

### hallazgos_*

| función | argumentos | devuelve | archivo |
|---|---|---|---|
| `hallazgos_comparativo` | `p_negocio_id bigint` | `jsonb` | `hallazgos_comparativo.sql` |
| `hallazgos_compras` | `p_negocio_id bigint` | `jsonb` | `hallazgos_compras__p_negocio_id_bigint.sql` |
| `hallazgos_compras` | `p_negocio_id bigint, p_contexto jsonb` | `jsonb` | `hallazgos_compras__p_negocio_id_bigint_p_contexto_jsonb.sql` |
| `hallazgos_generar` | `p_negocio_id bigint` | `jsonb` | `hallazgos_generar__p_negocio_id_bigint.sql` |
| `hallazgos_generar` | `p_negocio_id bigint, p_contexto jsonb` | `jsonb` | `hallazgos_generar__p_negocio_id_bigint_p_contexto_jsonb.sql` |

### informe_*

| función | argumentos | devuelve | archivo |
|---|---|---|---|
| `informe_base_bloque` | `p_hallazgos jsonb, p_servicio text` | `text` | `informe_base_bloque.sql` |
| `informe_estructura_seca` | `p_hallazgos jsonb, p_servicio text` | `jsonb` | `informe_estructura_seca.sql` |
| `informe_render` | `p_estructura jsonb, p_hallazgos jsonb, p_servicio text` | `text` | `informe_render.sql` |
| `informe_salud_bloque` | `p_salud jsonb, p_servicio text` | `text` | `informe_salud_bloque.sql` |

### ingesta_*

| función | argumentos | devuelve | archivo |
|---|---|---|---|
| `ingesta_cargar_inventario` | `p_documento_id bigint, p_filas jsonb` | `jsonb` | `ingesta_cargar_inventario.sql` |
| `ingesta_cargar_tabular` | `p_documento_id bigint, p_filas jsonb` | `jsonb` | `ingesta_cargar_tabular.sql` |
| `ingesta_cargar_tabular_detalle` | `p_documento_id bigint, p_filas jsonb` | `jsonb` | `ingesta_cargar_tabular_detalle.sql` |
| `ingesta_es_agregado` | `p_columnas jsonb` | `boolean` | `ingesta_es_agregado.sql` |
| `ingesta_fecha` | `p_valor jsonb, p_formato text` | `date` | `ingesta_fecha.sql` |
| `ingesta_huella` | `p_columnas text[]` | `text` | `ingesta_huella.sql` |
| `ingesta_identificar_tabular` | `p_documento_id bigint, p_columnas text[], p_muestra jsonb` | `jsonb` | `ingesta_identificar_tabular.sql` |
| `ingesta_inferir_decimales` | `p_muestra jsonb, p_columnas jsonb` | `jsonb` | `ingesta_inferir_decimales.sql` |
| `ingesta_inferir_formato_fecha` | `p_muestra jsonb, p_columna text` | `text` | `ingesta_inferir_formato_fecha.sql` |
| `ingesta_inferir_mapeo_sql` | `p_documento_id bigint, p_columnas text[], p_muestra jsonb` | `jsonb` | `ingesta_inferir_mapeo_sql.sql` |
| `ingesta_inferir_tipo` | `p_documento_id bigint, p_columnas text[]` | `text` | `ingesta_inferir_tipo.sql` |
| `ingesta_marcar_error` | `p_documento_id bigint, p_error text` | `jsonb` | `ingesta_marcar_error.sql` |
| `ingesta_num` | `p_valor jsonb, p_decimal text, p_miles text` | `numeric` | `ingesta_num.sql` |
| `ingesta_parsear_dian` | `p_documento_id bigint` | `jsonb` | `ingesta_parsear_dian.sql` |
| `ingesta_procesar_documento` | `p_documento_id bigint` | `jsonb` | `ingesta_procesar_documento.sql` |
| `ingesta_registrar_documento` | `p_sesion_id bigint, p_negocio_id bigint, p_nombre_archivo text, p_mime text, p_contenido bytea` | `jsonb` | `ingesta_registrar_documento.sql` |
| `ingesta_registrar_formato_inferido` | `p_documento_id bigint, p_columnas text[], p_mapeo jsonb` | `jsonb` | `ingesta_registrar_formato_inferido.sql` |
| `ingesta_registrar_formato_resuelto` | `p_documento_id bigint, p_columnas text[], p_mapeo jsonb` | `jsonb` | `ingesta_registrar_formato_resuelto.sql` |
| `ingesta_resolver_columnas` | `p_columnas text[]` | `jsonb` | `ingesta_resolver_columnas.sql` |
| `ingesta_resumen_documento` | `p_documento_id bigint` | `jsonb` | `ingesta_resumen_documento.sql` |
| `ingesta_resumen_sesion` | `p_sesion_id bigint` | `jsonb` | `ingesta_resumen_sesion.sql` |

### intencion_*

| función | argumentos | devuelve | archivo |
|---|---|---|---|
| `intencion_agregados` | `p_negocio_id bigint, p_metrica text, p_desde date, p_hasta date, p_producto bigint, p_proveedor text` | `jsonb` | `intencion_agregados.sql` |
| `intencion_detectar` | `p_texto text` | `text` | `intencion_detectar.sql` |
| `intencion_resolver` | `p_negocio_id bigint, p_texto text` | `jsonb` | `intencion_resolver.sql` |

### match_*

| función | argumentos | devuelve | archivo |
|---|---|---|---|
| `match_confirmar_alias` | `p_alias_id bigint, p_producto_id bigint` | `void` | `match_confirmar_alias.sql` |
| `match_resolver_documento` | `p_documento_id bigint` | `jsonb` | `match_resolver_documento.sql` |
| `match_resolver_producto` | `p_negocio_id bigint, p_texto text` | `jsonb` | `match_resolver_producto.sql` |

### portal_*

| función | argumentos | devuelve | archivo |
|---|---|---|---|
| `portal_alias_confirmar` | `p_alias_id bigint, p_producto_id bigint` | `jsonb` | `portal_alias_confirmar.sql` |
| `portal_alias_pendientes` | `p_limite integer` | `jsonb` | `portal_alias_pendientes.sql` |
| `portal_cartera` | `—` | `jsonb` | `portal_cartera.sql` |
| `portal_claim` | `p_clave text` | `bigint` | `portal_claim.sql` |
| `portal_conocimiento` | `p_tipo text` | `jsonb` | `portal_conocimiento.sql` |
| `portal_conocimiento_borrar` | `p_id bigint` | `jsonb` | `portal_conocimiento_borrar.sql` |
| `portal_conocimiento_guardar` | `p_titulo text, p_tipo text, p_contenido text, p_clave text, p_datos jsonb, p_id bigint, p_pendiente_id bigint` | `jsonb` | `portal_conocimiento_guardar.sql` |
| `portal_conteo_guardar` | `p_producto_id bigint, p_unidades numeric, p_fecha date` | `jsonb` | `portal_conteo_guardar.sql` |
| `portal_conteos` | `p_limite integer` | `jsonb` | `portal_conteos.sql` |
| `portal_cotizacion_guardar` | `p_items jsonb, p_cliente text, p_notas text, p_vigente_hasta date` | `jsonb` | `portal_cotizacion_guardar.sql` |
| `portal_cotizacion_publica` | `p_token text` | `jsonb` | `portal_cotizacion_publica.sql` |
| `portal_cotizacion_revocar` | `p_id bigint` | `jsonb` | `portal_cotizacion_revocar.sql` |
| `portal_cotizaciones` | `p_limite integer` | `jsonb` | `portal_cotizaciones.sql` |
| `portal_documentos` | `p_limite integer` | `jsonb` | `portal_documentos.sql` |
| `portal_factura_guardar` | `p_tercero text, p_total numeric, p_vencimiento date, p_numero text, p_emision date, p_nit text` | `jsonb` | `portal_factura_guardar.sql` |
| `portal_informe` | `p_id bigint` | `jsonb` | `portal_informe.sql` |
| `portal_informes` | `p_limite integer` | `jsonb` | `portal_informes.sql` |
| `portal_mov_nombre` | `p_raw jsonb, p_mapeo jsonb` | `text` | `portal_mov_nombre.sql` |
| `portal_movimientos` | `p_tipo text, p_limite integer` | `jsonb` | `portal_movimientos.sql` |
| `portal_movimientos_resumen` | `—` | `jsonb` | `portal_movimientos_resumen.sql` |
| `portal_negocio` | `—` | `bigint` | `portal_negocio.sql` |
| `portal_negocio_guardar` | `p_nit text` | `jsonb` | `portal_negocio_guardar.sql` |
| `portal_pago_registrar` | `p_factura_id bigint, p_valor numeric, p_fecha date, p_medio text` | `jsonb` | `portal_pago_registrar.sql` |
| `portal_pedido` | `—` | `jsonb` | `portal_pedido.sql` |
| `portal_pendientes` | `—` | `jsonb` | `portal_pendientes.sql` |
| `portal_perfil` | `—` | `jsonb` | `portal_perfil.sql` |
| `portal_productos` | `—` | `jsonb` | `portal_productos.sql` |
| `portal_recomendacion_accion` | `p_id bigint, p_accion text` | `jsonb` | `portal_recomendacion_accion.sql` |
| `portal_recomendaciones` | `p_limite integer` | `jsonb` | `portal_recomendaciones.sql` |
| `portal_sesion_abrir` | `p_token text` | `jsonb` | `portal_sesion_abrir.sql` |
| `portal_snapshots` | `p_limite integer` | `jsonb` | `portal_snapshots.sql` |
| `portal_token_crear` | `p_usuario_id bigint, p_minutos integer` | `text` | `portal_token_crear.sql` |

### recomendacion_*

| función | argumentos | devuelve | archivo |
|---|---|---|---|
| `recomendacion_accion` | `p_reco_id bigint, p_negocio_id bigint, p_accion text, p_usuario_id bigint` | `jsonb` | `recomendacion_accion.sql` |
| `recomendacion_marcar_cierre` | `p_reco_id bigint` | `void` | `recomendacion_marcar_cierre.sql` |
| `recomendacion_metrica_valor` | `p_negocio_id bigint, p_clave text, p_metrica text, p_desde date` | `numeric` | `recomendacion_metrica_valor.sql` |
| `recomendacion_objeto_evaluable` | `p_negocio_id bigint, p_clave text` | `boolean` | `recomendacion_objeto_evaluable.sql` |

### recomendaciones_*

| función | argumentos | devuelve | archivo |
|---|---|---|---|
| `recomendaciones_medir` | `p_negocio_id bigint` | `jsonb` | `recomendaciones_medir.sql` |
| `recomendaciones_negocio` | `p_negocio_id bigint, p_registro boolean` | `jsonb` | `recomendaciones_negocio.sql` |
| `recomendaciones_registrar` | `p_negocio_id bigint, p_ejecucion_id bigint` | `jsonb` | `recomendaciones_registrar.sql` |
| `recomendaciones_vigentes` | `p_negocio_id bigint, p_limite integer` | `jsonb` | `recomendaciones_vigentes.sql` |

### router_*

| función | argumentos | devuelve | archivo |
|---|---|---|---|
| `router_arranque_servicio` | `p_negocio_id bigint, p_chat_id bigint, p_servicio text` | `jsonb` | `router_arranque_servicio.sql` |
| `router_ctx` | `p_evento jsonb` | `jsonb` | `router_ctx.sql` |
| `router_h_admin` | `p_ctx jsonb` | `jsonb` | `router_h_admin.sql` |
| `router_h_comandos` | `p_ctx jsonb` | `jsonb` | `router_h_comandos.sql` |
| `router_h_intake` | `p_ctx jsonb` | `jsonb` | `router_h_intake.sql` |
| `router_h_recibiendo` | `p_ctx jsonb` | `jsonb` | `router_h_recibiendo.sql` |
| `router_h_sin_sesion` | `p_ctx jsonb` | `jsonb` | `router_h_sin_sesion.sql` |
| `router_marcar_editables` | `p_res jsonb, p_evento jsonb` | `jsonb` | `router_marcar_editables.sql` |
| `router_plan` | `p_negocio_id bigint, p_chat_id bigint` | `jsonb` | `router_plan.sql` |
| `router_portal` | `p_usuario_id bigint, p_chat_id bigint` | `jsonb` | `router_portal.sql` |
| `router_procesar_mensaje` | `p_evento jsonb` | `jsonb` | `router_procesar_mensaje.sql` |
| `router_respuesta` | `p_chat bigint, p_plantilla text, p_vars jsonb, p_teclado jsonb, p_acciones jsonb` | `jsonb` | `router_respuesta.sql` |

### snapshot_*

| función | argumentos | devuelve | archivo |
|---|---|---|---|
| `snapshot_anterior` | `p_negocio_id bigint, p_antes_de date` | `jsonb` | `snapshot_anterior.sql` |
| `snapshot_tomar` | `p_negocio_id bigint, p_origen text, p_ejecucion_id bigint` | `bigint` | `snapshot_tomar.sql` |
| `snapshot_umbrales` | `p_negocio_id bigint` | `jsonb` | `snapshot_umbrales.sql` |
| `snapshot_version` | `—` | `integer` | `snapshot_version.sql` |

### teclado_*

| función | argumentos | devuelve | archivo |
|---|---|---|---|
| `teclado_consentimiento` | `p_contexto text` | `jsonb` | `teclado_consentimiento.sql` |
| `teclado_intake` | `—` | `jsonb` | `teclado_intake.sql` |
| `teclado_markup` | `p_teclado jsonb, p_vars jsonb` | `jsonb` | `teclado_markup.sql` |
| `teclado_modulo` | `p_codigo text` | `jsonb` | `teclado_modulo.sql` |
| `teclado_modulos` | `—` | `jsonb` | `teclado_modulos.sql` |
| `teclado_recomendacion` | `p_reco_id bigint` | `jsonb` | `teclado_recomendacion.sql` |
| `teclado_recomendaciones` | `p_negocio_id bigint` | `jsonb` | `teclado_recomendaciones.sql` |
| `teclado_tipos_negocio` | `—` | `jsonb` | `teclado_tipos_negocio.sql` |

### otras

| función | argumentos | devuelve | archivo |
|---|---|---|---|
| `admin_reporte` | `p_cmd text` | `text` | `admin_reporte.sql` |
| `alertas_evaluar` | `—` | `jsonb` | `alertas_evaluar.sql` |
| `alias_pendientes` | `p_negocio_id bigint, p_limite integer` | `jsonb` | `alias_pendientes.sql` |
| `b64url` | `p bytea` | `text` | `b64url.sql` |
| `barra_10` | `p_valor numeric` | `text` | `barra_10.sql` |
| `canal_de_chat` | `p_chat_id bigint` | `text` | `canal_de_chat.sql` |
| `cartera_facturar_dian` | `p_documento_id bigint` | `jsonb` | `cartera_facturar_dian.sql` |
| `cartera_refacturar` | `p_negocio_id bigint` | `void` | `cartera_refacturar.sql` |
| `chat_de_usuario` | `p_usuario_id bigint` | `bigint` | `chat_de_usuario.sql` |
| `cifra_norm` | `p_num text` | `text` | `cifra_norm.sql` |
| `cifra_variantes` | `p_num text` | `text[]` | `cifra_variantes.sql` |
| `consulta_iniciar` | `p_usuario_id bigint, p_negocio_id bigint, p_chat_id bigint, p_pregunta text` | `jsonb` | `consulta_iniciar.sql` |
| `contexto_negocio_recuperar` | `p_negocio_id bigint, p_contexto jsonb` | `jsonb` | `contexto_negocio_recuperar.sql` |
| `ejecucion_cerrar` | `p_ejecucion_id bigint, p_estado text, p_resultado jsonb` | `jsonb` | `ejecucion_cerrar.sql` |
| `ejecucion_preparar` | `p_ejecucion_id bigint` | `jsonb` | `ejecucion_preparar.sql` |
| `esc_html` | `p_texto text` | `text` | `esc_html.sql` |
| `extensiones_aceptadas` | `—` | `text` | `extensiones_aceptadas.sql` |
| `fmt_decimal` | `p_num numeric` | `text` | `fmt_decimal.sql` |
| `informes_periodicos_disparar` | `—` | `jsonb` | `informes_periodicos_disparar.sql` |
| `jwt_firmar` | `p_payload jsonb, p_secreto text` | `text` | `jwt_firmar.sql` |
| `limpiar_marcado` | `p_texto text` | `text` | `limpiar_marcado.sql` |
| `mantenimiento_ciclo` | `—` | `jsonb` | `mantenimiento_ciclo.sql` |
| `mercado_compras_bienvenida` | `p_negocio_id bigint, p_chat_id bigint` | `jsonb` | `mercado_compras_bienvenida.sql` |
| `mes_es` | `p_fecha date` | `text` | `mes_es.sql` |
| `miles` | `p numeric` | `text` | `miles.sql` |
| `movimientos_limite_plan` | `—` | `trigger` | `movimientos_limite_plan.sql` |
| `nit_dv` | `p_nit text` | `integer` | `nit_dv.sql` |
| `norm_pregunta` | `p text` | `text` | `norm_pregunta.sql` |
| `norm_texto` | `p text` | `text` | `norm_texto.sql` |
| `pago_registrar` | `p_factura_id bigint, p_valor numeric, p_fecha date, p_medio text, p_origen text, p_usuario_id bigint` | `jsonb` | `pago_registrar.sql` |
| `parametro` | `p_negocio_id bigint, p_clave text` | `jsonb` | `parametro.sql` |
| `pedido_sugerido` | `p_negocio_id bigint` | `jsonb` | `pedido_sugerido.sql` |
| `perfil_negocio` | `p_negocio_id bigint` | `jsonb` | `perfil_negocio.sql` |
| `periodo_es` | `p_desde date, p_hasta date` | `text` | `periodo_es.sql` |
| `periodo_resolver` | `p_texto text, p_defecto text, p_hasta date` | `jsonb` | `periodo_resolver.sql` |
| `plan_desde` | `p_negocio_id bigint` | `date` | `plan_desde.sql` |
| `plantilla_cuerpo` | `p_clave text, p_defecto text` | `text` | `plantilla_cuerpo.sql` |
| `plantilla_cuerpo_srv` | `p_clave text, p_servicio text, p_defecto text` | `text` | `plantilla_cuerpo_srv.sql` |
| `resolver_plantilla` | `p_clave text, p_vars jsonb, p_teclado jsonb` | `jsonb` | `resolver_plantilla.sql` |
| `salud_negocio` | `p_negocio_id bigint` | `jsonb` | `salud_negocio.sql` |
| `semaforo` | `p_valor numeric` | `text` | `semaforo.sql` |
| `snapshots_backfill` | `—` | `integer` | `snapshots_backfill.sql` |
| `tercero_obtener` | `p_negocio_id bigint, p_nit text, p_nombre text` | `bigint` | `tercero_obtener.sql` |
| `unidades_es` | `p_n numeric` | `text` | `unidades_es.sql` |
| `usuario_de_canal` | `p_canal text, p_evento jsonb` | `bigint` | `usuario_de_canal.sql` |
| `usuario_de_telegram` | `p_evento jsonb` | `bigint` | `usuario_de_telegram.sql` |
| `validar_cifras` | `p_texto text, p_hallazgos jsonb` | `jsonb` | `validar_cifras.sql` |
| `wa_payload` | `p_para text, p_texto text, p_markup jsonb` | `jsonb` | `wa_payload.sql` |
| `wa_texto` | `p_html text` | `text` | `wa_texto.sql` |

## Vistas

| vista | columnas |
|---|---|
| `mov_visibles` | 14 |
| `v_balance_unidades` | 8 |
| `v_calidad_matching` | 10 |
| `v_cartera_edades` | 5 |
| `v_cartera_tercero` | 9 |
| `v_conocimiento_cobertura` | 7 |
| `v_conocimiento_faltante` | 10 |
| `v_consumo_negocio` | 6 |
| `v_costo_actual_producto` | 4 |
| `v_deriva_costo` | 6 |
| `v_ejecuciones_fallidas` | 6 |
| `v_embudo_servicios` | 6 |
| `v_margen_producto` | 7 |
| `v_negocios_alertables` | 5 |
| `v_negocios_informe_periodico` | 5 |
| `v_pareto_utilidad` | 5 |
| `v_perfil_negocio` | 15 |
| `v_precio_actual_producto` | 4 |
| `v_proveedor_mas_barato` | 6 |
| `v_rotacion_producto` | 7 |
| `v_salud_ingesta` | 5 |
| `v_sesiones_atascadas` | 7 |

## Tablas

| tabla | columnas |
|---|---|
| `alertas_enviadas` | 7 |
| `alias` | 7 |
| `conocimiento` | 12 |
| `conocimiento_pendiente` | 8 |
| `conteos_inventario` | 9 |
| `cotizaciones` | 11 |
| `documentos` | 14 |
| `ejecuciones` | 15 |
| `facturas` | 11 |
| `fallas` | 9 |
| `formatos_documento` | 11 |
| `identidades` | 7 |
| `intenciones` | 9 |
| `metricas_resultado` | 4 |
| `modulos` | 6 |
| `movimientos` | 14 |
| `negocios` | 7 |
| `pagos` | 8 |
| `parametros` | 3 |
| `plantillas` | 10 |
| `portal_tokens` | 6 |
| `productos` | 7 |
| `prompts` | 9 |
| `prompts_tecnicos` | 7 |
| `recomendaciones` | 23 |
| `schema_migraciones` | 2 |
| `servicios` | 8 |
| `servicios_entradas` | 5 |
| `sesiones` | 12 |
| `sinonimos_columna` | 3 |
| `snapshots_negocio` | 10 |
| `terceros` | 5 |
| `tipos_negocio` | 4 |
| `usuarios` | 10 |
