-- 003_semillas.sql — contenido base del sistema (no datos de cliente).
-- Formatos, un primer servicio, textos y umbrales por defecto. Todo idempotente.

-- === Formatos de documento =================================================
INSERT INTO formatos_documento (codigo, nombre, mime_patrones, extensiones, funcion_parseo, deteccion, mapeo) VALUES
  ('dian_xml', 'Factura electrónica DIAN (UBL 2.1)',
   ARRAY['application/xml','text/xml'], ARRAY['xml'],
   'ingesta_parsear_dian',
   -- raíces posibles; AttachedDocument envuelve al Invoice real en CDATA
   '{"raices": ["Invoice","CreditNote","DebitNote","AttachedDocument"]}'::jsonb,
   '{}'::jsonb),

  ('pos_csv_generico', 'Ventas POS (CSV genérico)',
   ARRAY['text/csv','application/csv','application/vnd.ms-excel'], ARRAY['csv'],
   'ingesta_cargar_tabular',
   '{}'::jsonb,
   -- clave = campo canónico que usa el código; valor = columna del CSV del POS.
   -- Un POS nuevo = otra fila con otro mapeo, no otra función.
   '{"columnas": {"fecha":"fecha","producto":"producto","categoria":"categoria",
                  "cantidad":"cantidad","valor_unitario":"precio_unitario",
                  "valor_total":"total"},
     "tipo": "venta", "separador": ",", "decimal": "."}'::jsonb)
ON CONFLICT (codigo) DO NOTHING;

-- === Primer servicio: ventas y compras =====================================
INSERT INTO servicios (codigo, nombre, descripcion, pasos, orden) VALUES
  ('ventas_compras', 'Análisis de ventas y compras',
   'Cruza compras (facturas DIAN) contra ventas (POS) y reporta márgenes, deriva de costo y productos que pierden plata.',
   '["identificar_negocio","cargar_compras","cargar_ventas","confirmar","ejecutar"]'::jsonb,
   10)
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO servicios_entradas (servicio_codigo, formato_codigo, obligatorio, min_archivos, max_archivos) VALUES
  ('ventas_compras', 'dian_xml',        true, 1, NULL),
  ('ventas_compras', 'pos_csv_generico', true, 1, 12)
ON CONFLICT (servicio_codigo, formato_codigo) DO NOTHING;

-- === Plantillas de mensajes ================================================
INSERT INTO plantillas (clave, cuerpo, variables) VALUES
  ('sistema.bienvenida',
   'Hola 👋 Soy Chasqui. Analizo las ventas y compras de tu negocio. Envíame /nueva para empezar.',
   '[]'),
  ('sistema.no_autorizado',
   'Antes de continuar necesito tu autorización para tratar los datos de tu negocio. Responde *acepto* para seguir.',
   '[]'),
  ('ingesta.ok',
   '✅ Recibí *{{nombre_archivo}}*. Llevo {{total}} archivo(s) en este lote.',
   '["nombre_archivo","total"]'),
  ('ingesta.parcial',
   '⚠️ Procesé {{ok}} de {{total}} archivos. Revisa *{{fallidos}}* y vuelve a enviarlos si quieres incluirlos.',
   '["ok","total","fallidos"]'),
  ('ingesta.error_archivo',
   '❌ No pude leer *{{nombre_archivo}}*: {{motivo}}. El resto del lote sigue en pie.',
   '["nombre_archivo","motivo"]'),
  ('ejecucion.en_curso',
   '⏳ Estoy analizando tu información. Te aviso apenas esté el informe.',
   '[]'),
  ('ejecucion.bloqueada_cupo',
   '🚧 Tu negocio superó el cupo mensual de análisis ({{limite}}). Se renueva el {{renovacion}}.',
   '["limite","renovacion"]'),
  ('ejecucion.entregada',
   '📄 Aquí está tu informe de *{{servicio}}*.',
   '["servicio"]'),
  ('ejecucion.fallida',
   '😕 Algo salió mal generando tu informe. Ya quedé avisado y lo reviso. Puedes intentar de nuevo en un rato.',
   '[]'),
  ('sesion.recordatorio',
   '👋 Dejaste un análisis a medias. Si quieres retomarlo, envíame los archivos que faltan; si no, lo cierro en unas horas.',
   '[]')
ON CONFLICT (clave) DO NOTHING;

-- === Parámetros globales por defecto (umbrales) ============================
-- Los pisa una fila por negocio cuando haga falta.
INSERT INTO parametros (negocio_id, clave, valor) VALUES
  (NULL, 'margen_minimo_pct',        '15'),
  (NULL, 'dias_cobertura_min',       '7'),
  (NULL, 'deriva_costo_alerta_pct',  '10'),
  (NULL, 'rotacion_baja_dias',       '30'),
  (NULL, 'costo_por_1k_tokens_usd',  '0.0003')
ON CONFLICT DO NOTHING;
