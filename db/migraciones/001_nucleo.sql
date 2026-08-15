-- 001_nucleo.sql — tablas de negocio.
-- Todo el comportamiento del sistema vive en filas; esto es el continente.
-- Extensiones (pgcrypto, pg_trgm, unaccent) ya instaladas por db/init/00_bases.sh.

-- === Dominios de estado ====================================================
CREATE TYPE rol_usuario     AS ENUM ('dueno', 'operador', 'admin');
CREATE TYPE estado_sesion   AS ENUM ('intake', 'recibiendo', 'procesando', 'completada', 'fallida', 'expirada');
CREATE TYPE estado_doc      AS ENUM ('pendiente', 'parseado', 'error');
CREATE TYPE estado_ejec     AS ENUM ('preparando', 'procesando', 'validando', 'completada', 'fallida', 'bloqueada');
CREATE TYPE tipo_movimiento AS ENUM ('compra', 'venta', 'ajuste');
CREATE TYPE origen_alias    AS ENUM ('exacto', 'trigram', 'manual', 'pendiente');

-- === Negocios y usuarios ===================================================
CREATE TABLE negocios (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre          text NOT NULL,
    nit             text,
    tipo            text,                         -- tienda, ferreteria, ...
    plan            text NOT NULL DEFAULT 'free',
    cupo_tokens_mes bigint NOT NULL DEFAULT 2000000,  -- 0 = bloqueado
    creado_en       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE usuarios (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    negocio_id         bigint REFERENCES negocios(id),
    telegram_user_id   bigint NOT NULL UNIQUE,
    telegram_chat_id   bigint,
    telegram_username  text,
    nombre             text,
    rol                rol_usuario NOT NULL DEFAULT 'operador',
    autorizacion_datos boolean NOT NULL DEFAULT false,
    autorizacion_fecha timestamptz,
    creado_en          timestamptz NOT NULL DEFAULT now()
);

-- === Catálogo de servicios (declarativo, no en nodos de n8n) ================
CREATE TABLE servicios (
    codigo      text PRIMARY KEY,
    nombre      text NOT NULL,
    descripcion text,
    pasos       jsonb NOT NULL DEFAULT '[]',  -- guion de intake, resuelto en Postgres
    orden       int  NOT NULL DEFAULT 100,
    activo      boolean NOT NULL DEFAULT true
);

-- === Formatos de documento (ingesta extensible por filas) ==================
-- Un formato nuevo es un INSERT + (a veces) una función de parseo. Nunca un nodo.
CREATE TABLE formatos_documento (
    codigo         text PRIMARY KEY,
    nombre         text NOT NULL,
    mime_patrones  text[] NOT NULL DEFAULT '{}',
    extensiones    text[] NOT NULL DEFAULT '{}',
    funcion_parseo text NOT NULL,               -- p.ej. ingesta_parsear_dian
    deteccion      jsonb NOT NULL DEFAULT '{}',  -- pistas de raíz/root-tag
    mapeo          jsonb NOT NULL DEFAULT '{}',  -- columnas proveedor -> canónico (tabular)
    activo         boolean NOT NULL DEFAULT true
);

CREATE TABLE servicios_entradas (
    servicio_codigo text NOT NULL REFERENCES servicios(codigo),
    formato_codigo  text NOT NULL REFERENCES formatos_documento(codigo),
    obligatorio     boolean NOT NULL DEFAULT true,
    min_archivos    int NOT NULL DEFAULT 1,
    max_archivos    int,
    PRIMARY KEY (servicio_codigo, formato_codigo)
);

-- === Sesiones (máquina de estados de la conversación) ======================
CREATE TABLE sesiones (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    usuario_id       bigint NOT NULL REFERENCES usuarios(id),
    negocio_id       bigint REFERENCES negocios(id),
    servicio_codigo  text REFERENCES servicios(codigo),
    paso             text,
    estado           estado_sesion NOT NULL DEFAULT 'intake',
    contexto         jsonb NOT NULL DEFAULT '{}',
    ultima_actividad timestamptz NOT NULL DEFAULT now(),
    creada_en        timestamptz NOT NULL DEFAULT now(),
    cerrada_en       timestamptz
);
CREATE INDEX idx_sesiones_usuario ON sesiones(usuario_id) WHERE cerrada_en IS NULL;
CREATE INDEX idx_sesiones_actividad ON sesiones(ultima_actividad) WHERE cerrada_en IS NULL;

-- === Documentos (archivo original en bytea) ================================
CREATE TABLE documentos (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sesion_id      bigint REFERENCES sesiones(id),
    negocio_id     bigint NOT NULL REFERENCES negocios(id),
    formato_codigo text REFERENCES formatos_documento(codigo),
    nombre_archivo text,
    mime           text,
    hash           bytea NOT NULL,               -- sha256 del contenido
    contenido      bytea NOT NULL,
    tamano         bigint,
    estado         estado_doc NOT NULL DEFAULT 'pendiente',
    error          text,
    creado_en      timestamptz NOT NULL DEFAULT now(),
    -- reintento idempotente: el mismo archivo del mismo negocio no se duplica
    UNIQUE (negocio_id, hash)
);
CREATE INDEX idx_documentos_sesion ON documentos(sesion_id);

-- === Productos y alias (matching) ==========================================
CREATE TABLE productos (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    negocio_id      bigint NOT NULL REFERENCES negocios(id),
    nombre_canonico text NOT NULL,
    unidad          text,
    categoria       text,
    creado_en       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_productos_negocio ON productos(negocio_id);
CREATE INDEX idx_productos_nombre_trgm ON productos USING gin (nombre_canonico gin_trgm_ops);

CREATE TABLE alias (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    negocio_id  bigint NOT NULL REFERENCES negocios(id),
    texto_norm  text NOT NULL,                   -- normalizado: minúsculas, sin acentos
    producto_id bigint REFERENCES productos(id),
    confianza   numeric NOT NULL DEFAULT 1.0,
    origen      origen_alias NOT NULL DEFAULT 'pendiente',
    creado_en   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (negocio_id, texto_norm)
);
CREATE INDEX idx_alias_texto_trgm ON alias USING gin (texto_norm gin_trgm_ops);
CREATE INDEX idx_alias_pendientes ON alias(negocio_id) WHERE producto_id IS NULL;

-- === Movimientos (compras/ventas normalizados) =============================
CREATE TABLE movimientos (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    negocio_id     bigint NOT NULL REFERENCES negocios(id),
    documento_id   bigint REFERENCES documentos(id),
    tipo           tipo_movimiento NOT NULL,
    fecha          date,
    producto_id    bigint REFERENCES productos(id),
    alias_id       bigint REFERENCES alias(id),
    cantidad       numeric,
    valor_unitario numeric,
    valor_total    numeric,
    impuesto       numeric DEFAULT 0,
    raw            jsonb,
    creado_en      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_mov_negocio_fecha ON movimientos(negocio_id, fecha);
CREATE INDEX idx_mov_producto ON movimientos(producto_id);
CREATE INDEX idx_mov_documento ON movimientos(documento_id);

-- === Ejecuciones (una corrida de servicio) =================================
CREATE TABLE ejecuciones (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sesion_id       bigint REFERENCES sesiones(id),
    negocio_id      bigint NOT NULL REFERENCES negocios(id),
    servicio_codigo text REFERENCES servicios(codigo),
    estado          estado_ejec NOT NULL DEFAULT 'preparando',
    prompt_id       bigint,
    hallazgos       jsonb,
    texto           text,
    pdf             bytea,
    tokens_prompt   int DEFAULT 0,
    tokens_salida   int DEFAULT 0,
    costo           numeric DEFAULT 0,
    error           text,
    inicio          timestamptz NOT NULL DEFAULT now(),
    fin             timestamptz
);
CREATE INDEX idx_ejec_negocio ON ejecuciones(negocio_id, inicio);
-- el reaper busca por aquí: ejecuciones colgadas en estados no terminales
CREATE INDEX idx_ejec_colgadas ON ejecuciones(inicio)
    WHERE estado IN ('preparando', 'procesando', 'validando');

-- === Fallas (lo que ve wf_error) ===========================================
CREATE TABLE fallas (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    workflow     text,
    ejecucion_id bigint REFERENCES ejecuciones(id),
    sesion_id    bigint REFERENCES sesiones(id),
    tipo         text,
    transitoria  boolean NOT NULL DEFAULT false,
    intentos     int NOT NULL DEFAULT 0,
    detalle      jsonb,
    creada_en    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_fallas_recientes ON fallas(creada_en);
