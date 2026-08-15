-- 040_cotizador.sql — el cotizador, en el portal (cierra la Fase 2).
--
-- El dueño arma la cotización eligiendo productos de su lista de precios
-- (conocimiento tipo 'precio') y la comparte con SU cliente por un enlace
-- público de solo lectura. Sin PDF: la cotización es una página.
--
-- Decisiones:
--   * Los ítems son un SNAPSHOT jsonb, no referencias: los precios cambian,
--     la cotización que el cliente ya recibió no puede cambiar con ellos.
--   * El token del enlace se guarda EN CLARO, a diferencia de portal_tokens:
--     el tendero necesita volver a copiar el mismo enlace mañana, y el
--     contenido está pensado para compartirse. Revocar es cambiar el estado.
--   * portal_cotizacion_publica es la SEGUNDA función que puede llamar un
--     visitante sin sesión (la primera fue portal_sesion_abrir, 033). Devuelve
--     una cotización abierta puntual a quien tenga el token (96 bits al azar)
--     y nada más: ni listas, ni precios vigentes, ni datos de otros negocios.

CREATE TABLE IF NOT EXISTS cotizaciones (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    negocio_id    bigint NOT NULL REFERENCES negocios(id),
    creado_por    bigint REFERENCES usuarios(id),
    cliente       text,
    notas         text,
    items         jsonb NOT NULL DEFAULT '[]'::jsonb,
    total         numeric NOT NULL DEFAULT 0,
    token         text NOT NULL UNIQUE,
    estado        text NOT NULL DEFAULT 'abierta',   -- abierta | revocada
    vigente_hasta date,
    creado_en     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_cotizaciones_negocio
    ON cotizaciones(negocio_id, creado_en DESC);

-- =============================================================================
-- 1. Crear (el portal manda los ítems ya elegidos; acá se validan y se congela
--    el total). No hay edición: una cotización compartida no se cambia por
--    debajo; se revoca y se hace otra.
-- =============================================================================

CREATE OR REPLACE FUNCTION portal_cotizacion_guardar(
    p_items   jsonb,
    p_cliente text DEFAULT NULL,
    p_notas   text DEFAULT NULL,
    p_vigente_hasta date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE
    v_negocio bigint := portal_negocio();
    v_usuario bigint := portal_claim('usuario_id');
    v_items   jsonb;
    v_total   numeric;
    v_id      bigint;
    v_token   text := encode(gen_random_bytes(12), 'hex');
BEGIN
    -- Normalizar y validar en un solo paso: título obligatorio, cantidad > 0,
    -- valor >= 0. El total de cada línea y el general se calculan acá; lo que
    -- mande el navegador en esos campos se ignora.
    SELECT jsonb_agg(jsonb_build_object(
             'titulo', i.titulo, 'unidad', i.unidad,
             'cantidad', i.cantidad, 'valor_unitario', i.valor,
             'total', round(i.cantidad * i.valor))),
           coalesce(sum(round(i.cantidad * i.valor)), 0)
      INTO v_items, v_total
    FROM (SELECT btrim(coalesce(e ->> 'titulo', ''))            AS titulo,
                 nullif(btrim(coalesce(e ->> 'unidad', '')), '') AS unidad,
                 (e ->> 'cantidad')::numeric                     AS cantidad,
                 (e ->> 'valor_unitario')::numeric               AS valor
          FROM jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) e) i
    WHERE i.titulo <> '' AND i.cantidad > 0 AND i.valor >= 0;

    IF v_items IS NULL OR jsonb_array_length(v_items) = 0 THEN
        RAISE EXCEPTION 'la cotización necesita al menos un producto con cantidad'
              USING ERRCODE = '22023';
    END IF;

    INSERT INTO cotizaciones (negocio_id, creado_por, cliente, notas, items,
                              total, token, vigente_hasta)
    VALUES (v_negocio, v_usuario, nullif(btrim(coalesce(p_cliente, '')), ''),
            nullif(btrim(coalesce(p_notas, '')), ''), v_items, v_total,
            v_token, p_vigente_hasta)
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'id', v_id, 'token', v_token,
                              'total', v_total);
END;
$$;

-- =============================================================================
-- 2. Listar y revocar
-- =============================================================================

CREATE OR REPLACE FUNCTION portal_cotizaciones(p_limite int DEFAULT 30)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_negocio bigint := portal_negocio();
BEGIN
    RETURN coalesce((
      SELECT jsonb_agg(jsonb_build_object(
               'id', c.id, 'cliente', c.cliente, 'total', c.total,
               'estado', c.estado, 'token', c.token,
               'items', jsonb_array_length(c.items),
               'vigente_hasta', c.vigente_hasta, 'creado_en', c.creado_en)
             ORDER BY c.creado_en DESC, c.id DESC)
      FROM (SELECT * FROM cotizaciones WHERE negocio_id = v_negocio
            ORDER BY creado_en DESC, id DESC
            LIMIT greatest(coalesce(p_limite, 30), 1)) c), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION portal_cotizacion_revocar(p_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE
    v_negocio bigint := portal_negocio();
    v_n       int;
BEGIN
    UPDATE cotizaciones SET estado = 'revocada'
    WHERE id = p_id AND negocio_id = v_negocio;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN jsonb_build_object('ok', v_n > 0);
END;
$$;

-- =============================================================================
-- 3. La vista del cliente final: pública, por token, solo lectura
-- =============================================================================
-- Un solo mensaje para "no existe" y "revocada": al que prueba tokens no se le
-- cuenta cuál fue. La vencida SÍ se muestra, con su fecha: el cliente tiene
-- que poder ver que venció, no adivinar por qué el enlace murió.

CREATE OR REPLACE FUNCTION portal_cotizacion_publica(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp AS $$
DECLARE v_out jsonb;
BEGIN
    SELECT jsonb_build_object(
             'ok', true,
             'negocio', jsonb_build_object('nombre', n.nombre, 'nit', n.nit,
                                           'tipo', n.tipo),
             'cliente', c.cliente, 'notas', c.notas, 'items', c.items,
             'total', c.total, 'creado_en', c.creado_en,
             'vigente_hasta', c.vigente_hasta,
             'vencida', c.vigente_hasta IS NOT NULL AND c.vigente_hasta < current_date)
      INTO v_out
    FROM cotizaciones c JOIN negocios n ON n.id = c.negocio_id
    WHERE c.token = coalesce(p_token, '') AND c.estado = 'abierta';

    RETURN coalesce(v_out, jsonb_build_object('ok', false, 'error', 'no_existe'));
END;
$$;

-- =============================================================================
-- 4. Permisos
-- =============================================================================

GRANT EXECUTE ON FUNCTION
      portal_cotizacion_guardar(jsonb, text, text, date),
      portal_cotizaciones(int),
      portal_cotizacion_revocar(bigint)
  TO portal_usuario;

-- El cliente final no tiene sesión: entra como anónimo con el token.
GRANT EXECUTE ON FUNCTION portal_cotizacion_publica(text)
  TO portal_anon, portal_usuario;

NOTIFY pgrst, 'reload schema';
