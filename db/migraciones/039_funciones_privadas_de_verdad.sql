-- 039_funciones_privadas_de_verdad.sql — la 034 no cerraba las funciones nuevas.
--
-- Lo que pasó: la 034 usó `ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE
-- EXECUTE ON FUNCTIONS FROM PUBLIC`, y las funciones de la 035 a la 038
-- nacieron igual con EXECUTE para PUBLIC (se vio en pg_proc.proacl:
-- `=X/chasqui`). No es un bug: la documentación de ALTER DEFAULT PRIVILEGES lo
-- dice en las notas — las entradas por esquema solo se SUMAN a los defaults
-- globales; un REVOKE por esquema no puede quitar los privilegios built-in.
-- Para quitarlos, el ALTER tiene que ser global (sin IN SCHEMA).
--
-- El agujero era chico —las portal_* nuevas son SECURITY DEFINER pero abortan
-- sin claims, y las internas corren como el rol llamador, que no tiene GRANT
-- sobre ninguna tabla— pero es exactamente la casualidad de la que la 034
-- decía que no había que depender.

-- (El REVOKE por esquema de la 034 fue un no-op completo: pg_default_acl está
-- vacío, no hay entrada que limpiar.)

-- 1. El default global, que sí puede quitar el built-in.
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- 2. Barrido de lo que nació abierto entre la 034 y acá (mismo DO de la 034).
--    Solo quita PUBLIC: los GRANT explícitos a portal_usuario/portal_anon no
--    se tocan, así que no hay nada que re-otorgar esta vez.
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

-- 3. PostgREST cachea el esquema: sin esto, los cambios de permisos y las
--    funciones nuevas no se ven hasta reiniciar el contenedor.
NOTIFY pgrst, 'reload schema';
