-- limpiar_datos.sql — deja la base como recién migrada: sin ningún dato de
-- negocio, con todo el comportamiento intacto.
--
-- NO es una migración: no va en db/migraciones/ y no se registra en
-- schema_migraciones. Es una herramienta de desarrollo, para volver a probar el
-- flujo completo desde cero sin recrear el volumen ni los contenedores.
--
--   bash bin/respaldo.sh                      # primero el respaldo, siempre
--   docker compose exec -T -e PGPASSWORD="$CHASQUI_DB_PASSWORD" postgres \
--     psql -v ON_ERROR_STOP=1 -U "$CHASQUI_DB_USER" -d "$CHASQUI_DB" \
--     < db/limpiar_datos.sql
--
-- QUÉ SE BORRA (todo lo que entró por el uso del sistema)
--   negocios, usuarios, identidades, sesiones, documentos, movimientos,
--   productos, alias, conteos_inventario, terceros, facturas, pagos,
--   ejecuciones, snapshots_negocio, recomendaciones, alertas_enviadas,
--   cotizaciones, fallas, conocimiento, conocimiento_pendiente, portal_tokens,
--   los umbrales por negocio y los formatos tabulares APRENDIDOS.
--
-- QUÉ SE CONSERVA (todo lo que instalaron las migraciones)
--   plantillas, plantillas_pdf, prompts, prompts_tecnicos, servicios,
--   servicios_entradas, modulos, tipos_negocio, parametros globales,
--   formatos_documento semilla (dian_xml, pos_csv_generico) y
--   schema_migraciones.
--
-- Todo en UNA transacción: o queda limpia, o no se tocó nada.

BEGIN;

-- 1. Los datos. Va en un solo TRUNCATE y SIN CASCADE a propósito: si mañana
--    aparece una tabla nueva que referencia a alguna de estas y nadie la agregó
--    a la lista, esto FALLA en vez de borrarla por sorpresa (o peor, de borrar
--    una tabla de configuración que la referencie).
--
--    `negocios` no está acá porque `parametros` la referencia y no se puede
--    truncar; se borra abajo con DELETE.
TRUNCATE TABLE
    alertas_enviadas,
    alias,
    conocimiento,
    conocimiento_pendiente,
    conteos_inventario,
    cotizaciones,
    documentos,
    ejecuciones,
    facturas,
    fallas,
    identidades,
    movimientos,
    pagos,
    portal_tokens,
    productos,
    recomendaciones,
    sesiones,
    snapshots_negocio,
    terceros,
    usuarios
RESTART IDENTITY;

-- 2. Umbrales ajustados para un negocio concreto. Los globales (negocio_id
--    NULL) son configuración: los puso una migración y se quedan.
DELETE FROM parametros WHERE negocio_id IS NOT NULL;

-- 3. Los negocios, ya sin nada que los referencie.
DELETE FROM negocios;
ALTER TABLE negocios ALTER COLUMN id RESTART;

-- 4. Los formatos tabulares que el sistema APRENDIÓ solo (migración 017): su
--    `mapeo` se infirió de los archivos que se cargaron, así que pertenecen a
--    esos datos y no a la instalación. Los de clase 'documento' (dian_xml) y el
--    pos_csv_generico son semilla y no se tocan.
--
--    Si querés conservar lo aprendido —por ejemplo para no volver a gastar
--    tokens infiriendo el layout del POS de un cliente—, comentá este bloque.
DELETE FROM servicios_entradas
 WHERE formato_codigo IN (SELECT codigo FROM formatos_documento
                           WHERE clase = 'tabular' AND codigo LIKE 'tabular\_%');
DELETE FROM formatos_documento
 WHERE clase = 'tabular' AND codigo LIKE 'tabular\_%';

COMMIT;

-- Verificación: las tres primeras columnas tienen que dar 0.
SELECT (SELECT count(*) FROM negocios)    AS negocios,
       (SELECT count(*) FROM movimientos) AS movimientos,
       (SELECT count(*) FROM usuarios)    AS usuarios,
       (SELECT count(*) FROM plantillas)  AS plantillas_conservadas,
       (SELECT count(*) FROM servicios)   AS servicios_conservados,
       (SELECT count(*) FROM prompts WHERE activo) AS prompts_activos;
