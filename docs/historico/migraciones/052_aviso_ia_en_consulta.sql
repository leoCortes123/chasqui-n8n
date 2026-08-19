-- 052_aviso_ia_en_consulta.sql — la respuesta del chat también la escribe la IA.
--
-- La 051 puso la advertencia al pie del informe (`ejecucion.entregada`), pero
-- se olvidó del otro camino de entrega: `ejecucion.entregada.consulta`, con el
-- que se contestan las preguntas libres del dueño. Ese texto lo redacta el
-- mismo modelo y se lee igual de en serio. Va la versión corta: es una
-- respuesta de chat, no un informe, y repetir el párrafo completo en cada
-- pregunta lo volvería ruido que nadie lee.

UPDATE plantillas SET cuerpo =
'{{texto}}

<i>⚠️ Respuesta generada con IA a partir de tus datos: puede equivocarse. Verificá antes de decidir.</i>',
  version = version + 1
WHERE clave = 'ejecucion.entregada.consulta';

NOTIFY pgrst, 'reload schema';
