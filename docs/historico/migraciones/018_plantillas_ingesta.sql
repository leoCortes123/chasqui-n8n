-- 018_plantillas_ingesta.sql — el mensaje deja de ser "está mal y ya".
--
-- Antes: ingesta.ok solo confirmaba el nombre del archivo, así que un archivo
-- cargado con todos los campos en NULL se veía idéntico a uno bueno. Y el
-- motivo de error venía hardcodeado como 'no se pudo leer' en el nodo Respuesta
-- de wf_ingesta, o sea que la plantilla tenía una variable que nunca traía
-- información. Ahora ambas reportan lo que la base entendió de verdad.

UPDATE plantillas SET cuerpo =
'✅ Leí *{{nombre_archivo}}*: {{filas}} registros{{rango}}, {{productos}} productos, {{total}} en total.{{aviso_sin_resolver}}

Seguí enviando archivos o escribí */listo* cuando termines.',
  variables = '["nombre_archivo","filas","rango","productos","total","aviso_sin_resolver"]'::jsonb,
  version = version + 1
WHERE clave = 'ingesta.ok';

UPDATE plantillas SET cuerpo =
'❌ No pude usar *{{nombre_archivo}}*.

{{motivo}}

El resto de los archivos sigue en pie: podés enviarlo corregido o seguir con los demás.',
  variables = '["nombre_archivo","motivo"]'::jsonb,
  version = version + 1
WHERE clave = 'ingesta.error_archivo';

INSERT INTO plantillas (clave, cuerpo, formato, variables) VALUES
('ingesta.formato_nuevo',
 '🔍 *{{nombre_archivo}}* viene en un formato que no conocía. Lo estudié y aprendí a leerlo: {{filas}} registros{{rango}}, {{total}} en total.

Si algún número te parece raro, avisame y lo reviso antes de analizar.',
 'markdown',
 '["nombre_archivo","filas","rango","total"]'::jsonb),

('ingesta.pedir_columnas',
 '🤔 Abrí *{{nombre_archivo}}* pero no encontré las columnas que necesito.

{{motivo}}

Necesito por lo menos una columna con la *fecha* y una con el *valor*. Si el archivo tiene títulos o filas en blanco arriba de los encabezados, mandámelo empezando por la fila de encabezados.',
 'markdown',
 '["nombre_archivo","motivo"]'::jsonb)
ON CONFLICT (clave) DO UPDATE
  SET cuerpo = EXCLUDED.cuerpo, variables = EXCLUDED.variables, activo = true;

-- sistema.pedir_archivos deja de nombrar formatos concretos: la ingesta ya no
-- exige un esquema, así que prometer "XML de la DIAN y CSV del POS" subestima
-- lo que el sistema acepta y asusta a quien no sabe qué exporta su POS.
UPDATE plantillas SET cuerpo =
'Perfecto, *{{servicio}}*.

Mandame lo que tengas: las facturas XML de la DIAN, o el archivo de ventas que exporte tu sistema (Excel, CSV, lo que sea). No importa cómo se llamen las columnas, yo me arreglo.

Cuando termines, escribí */listo*.',
  version = version + 1
WHERE clave = 'sistema.pedir_archivos';
