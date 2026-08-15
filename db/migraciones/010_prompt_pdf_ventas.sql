-- 010_prompt_pdf_ventas.sql — contenido del servicio ventas_compras:
-- el prompt del LLM y la plantilla de PDF. Iterar el tono = INSERT de otra
-- versión + apagar la anterior, nunca tocar un nodo de n8n.

INSERT INTO prompts (servicio_codigo, version, sistema, usuario, modelo, temperatura, max_tokens)
VALUES (
  'ventas_compras', 1,
  -- sistema: rol y reglas duras
  'Eres el analista de un tendero colombiano. Escribes claro, directo y en '
  || 'español de Colombia, sin tecnicismos. REGLA ABSOLUTA: solo puedes usar '
  || 'cifras que aparezcan textualmente en los HALLAZGOS que te doy. Está '
  || 'prohibido calcular, estimar o inventar un número que no esté ahí. Si un '
  || 'dato no está, dilo con palabras, nunca lo rellenes. Habla de pesos '
  || 'colombianos. No saludes ni te despidas: entrega el análisis.',
  -- usuario: plantilla; {{hallazgos}} lo inyecta n8n desde ejecucion_preparar
  'Con base EXCLUSIVAMENTE en estos hallazgos, escribe un informe breve para el '
  || 'dueño del negocio. Estructura: (1) qué productos están dejando poco o '
  || 'ningún margen y qué hacer; (2) productos cuyo costo subió y hay que '
  || 'revisar el precio de venta; (3) productos que se van a agotar pronto; '
  || '(4) los pocos productos que concentran la ganancia. Máximo 250 palabras.'
  || E'\n\nHALLAZGOS:\n{{hallazgos}}',
  'deepseek-v4-flash', 0.2, 1200
)
ON CONFLICT DO NOTHING;

INSERT INTO plantillas_pdf (servicio_codigo, version, html, css)
VALUES (
  'ventas_compras', 1,
  $html$<!doctype html>
<html lang="es"><head><meta charset="utf-8"><style>{{css}}</style></head>
<body>
  <header>
    <h1>Informe de ventas y compras</h1>
    <p class="sub">{{negocio_nombre}} · {{fecha}}</p>
  </header>
  <main>{{cuerpo_html}}</main>
  <footer>Generado por Chasqui · Las cifras provienen de tus documentos.</footer>
</body></html>$html$,
  $css$
  body{font-family:'Helvetica Neue',Arial,sans-serif;color:#1a1a1a;margin:0;padding:40px;line-height:1.5}
  header h1{font-size:22px;margin:0 0 4px}
  .sub{color:#666;margin:0 0 24px;font-size:13px}
  main{font-size:14px}
  main h2{font-size:16px;border-bottom:2px solid #e0e0e0;padding-bottom:4px;margin-top:20px}
  footer{margin-top:32px;color:#999;font-size:11px;border-top:1px solid #eee;padding-top:8px}
  $css$
)
ON CONFLICT DO NOTHING;
