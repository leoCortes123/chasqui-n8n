# Trazabilidad

De la documentación a la implementación. Toda ruta es relativa a la raíz del
repositorio y fue verificada el 2026-08-19.

Herramientas del propio proyecto para seguir profundizando:

```bash
less db/actual/INDICE.md                 # 160 funciones por familia, con firma
cat  db/actual/funciones/<nombre>.sql    # la definición vigente
bash bin/impacto.sh <función>            # quién la llama y a quién llama
bash bin/impacto.sh <tabla> --tabla      # qué funciones usan una tabla
cat  decisiones/INDICE.md                # las 18 decisiones vigentes
```

---

## Componente → implementación

### Entrada por Telegram
```
wf_router
  -> bin/gen_wf_router.py                (generador; FUENTE)
  -> workflows/wf_router.json            (generado)
  -> nodo "Normalizar"                   verificación del secreto, normalización
  -> nodo "Router"                       SELECT router_marcar_editables(
                                                router_procesar_mensaje(ev), ev)
  -> db/actual/funciones/router_procesar_mensaje.sql
  -> db/actual/funciones/router_marcar_editables.sql
  -> tabla: sesiones, usuarios, identidades
  -> consumidor: wf_enviar, wf_ingesta, wf_ejecutar
```

### Máquina de estados
```
router_procesar_mensaje
  -> db/actual/funciones/router_ctx.sql            contexto + usuario_de_canal
  -> db/actual/funciones/router_h_admin.sql        6 comandos de admin
  -> db/actual/funciones/router_h_comandos.sql     251 líneas, 13 ramas
  -> db/actual/funciones/router_h_sin_sesion.sql   incluye consulta_iniciar
  -> db/actual/funciones/router_h_intake.sql       elección de servicio
  -> db/actual/funciones/router_h_recibiendo.sql   /listo -> carga_evaluar
  -> db/actual/funciones/router_respuesta.sql      forma de la salida
  -> decisión: decisiones/ROUTER-001.md
  -> banco: db/pruebas/router_casos.sql (67 casos)
```

### Ingesta de un archivo tabular
```
wf_ingesta  (bin/gen_wf_ingesta.py)
  nodo Registrar    -> db/actual/funciones/ingesta_registrar_documento.sql
                       tabla documentos (UNIQUE negocio_id, hash)
  nodo Identificar  -> db/actual/funciones/ingesta_identificar_tabular.sql
                       -> ingesta_huella.sql
                       -> ingesta_inferir_mapeo_sql.sql
                          -> ingesta_resolver_columnas.sql  (tabla sinonimos_columna)
                          -> ingesta_inferir_decimales.sql
                          -> ingesta_inferir_formato_fecha.sql
                          -> ingesta_inferir_tipo.sql
                       -> ingesta_registrar_formato_resuelto.sql
  nodo InferirMapeo -> prompts_tecnicos clave 'ingesta.inferir_mapeo'
  nodo RegistrarFormato -> ingesta_registrar_formato_inferido.sql
  nodo CargarTabular    -> ingesta_cargar_tabular.sql
                           -> ingesta_es_agregado.sql / ingesta_marcar_descartado.sql
                           -> ingesta_cargar_tabular_detalle.sql
                              -> ingesta_fecha.sql, ingesta_num.sql
                              -> tabla movimientos (trigger movimientos_limite_plan)
  nodo Resolver     -> match_resolver_documento.sql -> match_resolver_producto.sql
  decisión          -> decisiones/INGESTA-001.md
  bancos            -> db/pruebas/ingesta_sin_modelo.sql
```

### Ingesta DIAN
```
wf_ingesta nodo Procesar
  -> db/actual/funciones/ingesta_procesar_documento.sql   (despacho por clase)
  -> db/actual/funciones/ingesta_parsear_dian.sql         (XMLTABLE, UBL 2.1)
  -> db/actual/funciones/cartera_facturar_dian.sql        (facturas + terceros)
     -> db/actual/funciones/tercero_obtener.sql
     -> tabla facturas (UNIQUE documento_id), terceros
  fixtures -> docs/ejemplos/dian_oficiales/ (13 XML del set oficial)
```

### Panel de carga
```
carga_evaluar  (db/actual/funciones/carga_evaluar.sql)
  -> pg_advisory_xact_lock(hashtextextended('carga_panel:'||sesion, 0))
  -> carga_resumen.sql        conteos por estado + periodo + descargas fallidas
  -> carga_hay_con_que.sql
  -> carga_arrancar.sql       UPDATE ... WHERE estado='recibiendo' RETURNING
  -> carga_panel.sql          arma el texto con resolver_plantilla
  columnas   -> sesiones.panel_mensaje_id, .analisis_pedido_en, .panel_pedido_en
  plantillas -> carga.panel, carga.panel_esperando, carga.panel_analizando
  workflow   -> wf_enviar, rama panel (PanelResolver..PanelFijar)
  migraciones-> 071, 075, 076
  decisión   -> decisiones/INGESTA-002.md
  banco      -> db/pruebas/carga_sin_perdida.sql
```

### Análisis
```
wf_ejecutar  (bin/gen_wf_ejecutar.py)
  nodo Preparar -> db/actual/funciones/ejecucion_preparar.sql
                   -> v_consumo_negocio (cupo)
                   -> EXECUTE servicios.funcion_hallazgos
                      -> hallazgos_generar__p_negocio_id_bigint.sql
                         -> salud_negocio.sql
                         -> recomendaciones_negocio.sql   (683 líneas, 11 reglas)
                         -> hallazgos_comparativo.sql -> snapshot_anterior.sql
                         -> vistas v_margen_producto, v_rotacion_producto,
                            v_deriva_costo, v_pareto_utilidad, mov_visibles
                      -> hallazgos_compras__p_negocio_id_bigint.sql
                      -> contexto_negocio_recuperar.sql
                   -> tabla prompts (uq_prompt_activo)
  nodo DeepSeek1/2 -> ${DEEPSEEK_BASE_URL}/chat/completions   (bin/wf_lib.py:LLM_URL)
  nodo Render1/2   -> db/actual/funciones/informe_render.sql
                      -> informe_salud_bloque.sql, informe_base_bloque.sql
                      -> plantilla_cuerpo_srv.sql, esc_html.sql, limpiar_marcado.sql
                      -> tabla plantillas (informe.*)
  nodo Validar1/2  -> db/actual/funciones/validar_cifras.sql
                      -> cifra_norm.sql, cifra_variantes.sql
  nodo SecaSQL     -> db/actual/funciones/informe_estructura_seca.sql
  nodo Cerrar      -> db/actual/funciones/ejecucion_cerrar.sql
                      -> snapshot_tomar.sql
                      -> recomendaciones_registrar.sql
                      -> recomendaciones_medir.sql
                      -> chat_de_usuario.sql
  decisiones -> decisiones/CORE-001.md, INFORME-001.md, HALLAZGOS-001.md
```

### Reglas de negocio
```
Las 11 reglas -> db/actual/funciones/recomendaciones_negocio.sql
   R1  costo           líneas ~ 95-145   CTE r_costo
   R2  proveedor       ~146-167          CTE alternativa + r_proveedor
   R3  margen          ~168-202          CTE r_margen
   R4  agota           ~203-250          CTE r_agota
   R5  quieto          ~251-295          CTE r_quieto
   R6  dependencia     ~296-320          CTE gasto_prov + r_dependencia
   R7  sin_ventas      ~330-370          CTE venta_hist + r_sin_ventas
   R8  proveedor_sube  ~372-424          CTEs compras_serie/delta/sube
   R9  margen_cae      ~426-476          CTEs snaps/margen_hist
   R10 vs_ano_anterior ~478-508          CTE anual + r_vs_ano
   R11 cartera         ~510-570          CTE cartera_mora + r_cartera
   priorización        ~590-627          CTE priorizadas
   topes               ~636-652          CTEs visibles + salida
umbrales -> tabla parametros (35 filas globales)
detalle  -> docs/business-rules.md
banco    -> db/pruebas/reglas_comparativas.sql (R7-R10)
```

### Salida al canal
```
wf_enviar  (bin/gen_wf_enviar.py)
  nodo Resolver     -> db/actual/funciones/resolver_plantilla.sql
                       -> teclado_markup.sql (tope parametros.teclado_max_filas)
                       -> esc_html.sql
                       -> tabla plantillas (82 filas)
                       -> canal_de_chat.sql
                       -> wa_payload.sql -> wa_texto.sql
  nodos EnviarTexto{0..6} / EditarTexto{0..6}   (forma literal del teclado)
  nodos PanelCrear{0..2} / PanelEditar{0..2}    + PanelGuardar + PanelFijar
                    -> carga_panel_registrar.sql
```

### Proactividad
```
wf_cron  (bin/gen_wf_cron.py)  -> Schedule 5 min
  nodo Mantenimiento -> db/actual/funciones/mantenimiento_ciclo.sql
     paso 1 reaper       -> ejecuciones + sesiones + plantilla ejecucion.fallida
     paso 2 expiración   -> sesiones + plantilla sesion.recordatorio
     paso 3 alertas      -> alertas_evaluar.sql
                            -> v_negocios_alertables
                            -> recomendaciones_negocio(negocio, TRUE)
                            -> tabla alertas_enviadas
                            -> plantilla alerta.hallazgo
     paso 4 periódicos   -> informes_periodicos_disparar.sql
                            -> v_negocios_informe_periodico
                            -> plantilla informe.periodico_aviso
  nodo Avisar   -> wf_enviar (mode: each)
  nodo Analizar -> wf_ejecutar (mode: each)
  decisión -> decisiones/ALERTAS-001.md
```

### Portal
```
Caddyfile /api/*  -> postgrest:3000
  portal_sesion_abrir.sql   -> jwt_firmar.sql, b64url.sql, portal_tokens
  portal_claim.sql          -> request.jwt.claims
  portal_negocio.sql        -> ERRCODE 42501 si falta
  27 funciones portal_*     -> db/actual/funciones/portal_*.sql
Caddyfile /portal/* -> portal/publico/index.html   (const API='/api', rpc())
                       portal/publico/cotizacion.html
roles -> bin/preparar-portal.sh
decisión -> decisiones/PORTAL-001.md
```

### Memoria
```
snapshot_tomar.sql        -> snapshots_negocio (uq_snapshot_dia)
   -> snapshot_umbrales.sql, snapshot_version.sql
   -> v_calidad_matching, v_pareto_utilidad, v_balance_unidades
snapshot_anterior.sql     -> hallazgos_comparativo.sql
recomendaciones_registrar.sql -> recomendaciones
recomendacion_marcar_cierre.sql -> datos.valor_al_cerrar
recomendaciones_medir.sql -> metricas_resultado (11 filas)
   -> recomendacion_metrica_valor.sql
   -> recomendacion_objeto_evaluable.sql
conocimiento_guardar.sql / conocimiento_buscar.sql -> conocimiento
conocimiento_pendiente_registrar.sql -> conocimiento_pendiente
detalle -> docs/memory-and-state.md
```

---

## Tabla → quién la escribe y quién la lee

| Tabla | Escriben | Leen |
|---|---|---|
| `negocios` | `usuario_de_canal`, `router_h_comandos` (tipo), `portal_negocio_guardar` (nit) | `plan_desde`, `router_plan`, `hallazgos_generar`, `perfil_negocio` |
| `usuarios` | `usuario_de_canal`, `router_h_comandos` (autorización) | `router_ctx`, `wf_error` (admins), vistas de alerta |
| `identidades` | `usuario_de_canal` | `canal_de_chat`, `chat_de_usuario`, `carga_panel` |
| `sesiones` | `router_h_*`, `carga_*`, `consulta_iniciar`, `ejecucion_cerrar`, `mantenimiento_ciclo`, `informes_periodicos_disparar` | `router_procesar_mensaje`, `carga_*`, `ejecucion_preparar` |
| `documentos` | `ingesta_registrar_documento`, `ingesta_marcar_error/_descartado`, `ingesta_cargar_*`, trigger de plan | `carga_resumen`, `carga_hay_con_que`, `portal_documentos`, `informe_base_bloque`, `v_salud_ingesta` |
| `movimientos` | `ingesta_cargar_tabular_detalle`, `ingesta_parsear_dian`, `cartera_facturar_dian` (tipo, tercero), `match_resolver_documento` (producto) | **todo el análisis vía `mov_visibles`** |
| `productos` | `match_resolver_documento` | vistas de margen, rotación, balance; `portal_productos` |
| `alias` | `match_resolver_producto`, `match_confirmar_alias`, `portal_alias_confirmar` | `v_calidad_matching`, `alias_pendientes` |
| `terceros` | `tercero_obtener` | `facturas`, `v_cartera_tercero`, regla `cartera` |
| `facturas` | `cartera_facturar_dian`, `portal_factura_guardar`, `pago_registrar` | `salud_negocio` (liquidez), regla `cartera`, `portal_cartera` |
| `pagos` | `pago_registrar`, `portal_pago_registrar` | `portal_cartera` |
| `conteos_inventario` | `portal_conteo_guardar`, `ingesta_cargar_inventario` (sin ruta viva) | `v_balance_unidades` |
| `ejecuciones` | `carga_arrancar`, `consulta_iniciar`, `informes_periodicos_disparar`, `ejecucion_preparar`, `ejecucion_cerrar`, `mantenimiento_ciclo` | `v_consumo_negocio`, `v_ejecuciones_fallidas`, `portal_informes` |
| `snapshots_negocio` | `snapshot_tomar`, `snapshots_backfill` (sin llamador) | `snapshot_anterior`, regla `margen_cae`, `portal_snapshots` |
| `recomendaciones` | `recomendaciones_registrar`, `recomendacion_accion`, `recomendacion_marcar_cierre`, `recomendaciones_medir` | `recomendaciones_vigentes`, `pedido_sugerido`, `teclado_recomendaciones`, `portal_recomendaciones`, `perfil_negocio` |
| `alertas_enviadas` | `alertas_evaluar` | `alertas_evaluar` (cooldown) |
| `conocimiento` | `conocimiento_guardar`, `portal_conocimiento_*`, `recomendacion_accion('precio')` | `conocimiento_buscar` |
| `conocimiento_pendiente` | `conocimiento_pendiente_registrar` | `v_conocimiento_faltante`, `portal_pendientes` |
| `portal_tokens` | `portal_token_crear`, `portal_sesion_abrir` | `portal_sesion_abrir` |
| `fallas` | `wf_error`, `mantenimiento_ciclo`, `ejecucion_cerrar` | `admin_reporte` (no directamente: usa `v_ejecuciones_fallidas`) |
| `formatos_documento` | `ingesta_registrar_formato_resuelto/_inferido` | `ingesta_registrar_documento`, `ingesta_identificar_tabular`, `extensiones_aceptadas` |
| `plantillas` | **sólo migraciones** | `resolver_plantilla`, `plantilla_cuerpo_srv`, `router_marcar_editables` |
| `prompts`, `prompts_tecnicos` | **sólo migraciones** | `ejecucion_preparar`, nodo `Identificar` de `wf_ingesta` |
| `parametros` | **sólo migraciones** y `bin/registrar-webhook.sh` (`portal_url_base`) | `parametro()`, usada por ~30 funciones |
| `servicios`, `servicios_entradas`, `modulos`, `intenciones`, `metricas_resultado`, `sinonimos_columna`, `tipos_negocio` | **sólo migraciones** | router, ingesta, análisis, medición |

---

## Decisión → dónde se comprueba

| Decisión | Comprobación mecánica |
|---|---|
| `CORE-001` | `validar_cifras` + los prompts + `informe_render` |
| `CORE-002` | `movimientos_limite_plan` devuelve NEW siempre; `mov_visibles` |
| `CORE-003` | tabla `recomendaciones` + `recomendaciones_medir` |
| `CONTENIDO-001` | 203 filas en 12 tablas; `resolver_plantilla` |
| `INGESTA-001` | `ingesta_identificar_tabular` (3 escalones); banco `ingesta_sin_modelo` |
| `INGESTA-002` | `router_procesar_mensaje` rama `procesando`; `carga_evaluar`; banco `carga_sin_perdida` |
| `HALLAZGOS-001` | `salud_negocio` (NULL no promedia) |
| `DATOS-001` | `v_balance_unidades.origen_stock` propagado hasta el texto |
| `PORTAL-001` | `role_table_grants` vacío; 28 GRANT explícitos; `portal_claim` |
| `ALERTAS-001` | `alertas_evaluar` + `parametros alerta_*` |
| `ROUTER-001` | 5 handlers separados; migraciones 074-076 no copian el router |
| `MIGRACION-001` | `bin/verificar.sh` chequeo 9 |
| `BASE-001` | `bin/verificar.sh` chequeo 8 |
| `PRODUCTO-002` | sin Gotenberg en el compose; `ejecuciones.pdf` en NULL |
| `PLANES-001` | orden de los bloques en `router_h_comandos` |
| `INFORME-001` | `informe_base_bloque` + `validar_cifras` + `cifra_variantes` |
