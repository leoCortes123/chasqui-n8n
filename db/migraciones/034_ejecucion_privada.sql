-- 034_ejecucion_privada.sql — ninguna función es pública por defecto.
--
-- Postgres le da EXECUTE a PUBLIC sobre toda función nueva. Mientras el único
-- cliente de la base fue n8n —conectado como el dueño— eso daba igual. Con
-- PostgREST adelante deja de darlo: PostgREST publica como endpoint CUALQUIER
-- función que el rol de la petición pueda ejecutar, y `portal_anon` hereda de
-- PUBLIC. O sea que sin esto, /api/rpc/router_procesar_mensaje existe para
-- cualquiera que sepa el nombre.
--
-- Lo comprobado antes de escribir esto: esas llamadas fallaban igual, pero por
-- casualidad —"permission denied for table conocimiento"—, porque el rol no
-- tiene GRANT sobre las tablas. Depender de eso es depender de que ninguna
-- función futura sea SECURITY DEFINER por descuido. La regla correcta es que
-- no se pueda ni llamarlas.
--
-- Dos piezas, porque una sola no alcanza:
--   1. barrido de lo que ya existe;
--   2. ALTER DEFAULT PRIVILEGES, para que las funciones de las migraciones que
--      vengan nazcan cerradas sin que haya que acordarse.
--
-- Las funciones de EXTENSIONES quedan fuera del barrido a propósito: unaccent,
-- similarity, digest y hmac son de otro dueño y sí las necesita PUBLIC —el
-- propio rol de la aplicación las usa dentro de norm_texto y jwt_firmar—.

-- 1. Barrido de lo existente (todo lo que no venga de una extensión).
DO $$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS f
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND NOT EXISTS (SELECT 1 FROM pg_depend d
                          WHERE d.classid = 'pg_proc'::regclass
                            AND d.objid = p.oid AND d.deptype = 'e')
    LOOP
        EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', r.f);
    END LOOP;
END
$$;

-- 2. Lo que se cree de acá en más. El dueño de la base es quien corre las
--    migraciones, así que basta con su default.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- 3. Los permisos del portal se vuelven a otorgar: el barrido de arriba también
--    se los llevó por delante (venían de PUBLIC en el caso de portal_anon).
GRANT EXECUTE ON FUNCTION portal_sesion_abrir(text) TO portal_anon;

GRANT EXECUTE ON FUNCTION
      portal_perfil(),
      portal_conocimiento(text),
      portal_conocimiento_guardar(text, text, text, text, jsonb, bigint, bigint),
      portal_conocimiento_borrar(bigint),
      portal_pendientes(),
      portal_informes(int),
      portal_informe(bigint)
  TO portal_usuario;
