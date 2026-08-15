-- 002_contenido.sql — el comportamiento como datos.
-- Textos, prompts, plantillas de PDF y umbrales salen de los nodos de n8n
-- y viven aquí. Iterar el tono de un informe es un INSERT, no editar un nodo.

-- === Plantillas de mensajes ================================================
-- respuestas[] de router_procesar_mensaje devuelve {plantilla, vars}.
-- El texto final se resuelve en Postgres, nunca en n8n.
CREATE TABLE plantillas (
    clave     text PRIMARY KEY,          -- p.ej. ingesta.ok
    canal     text NOT NULL DEFAULT 'telegram',
    cuerpo    text NOT NULL,             -- con {{placeholders}}
    formato   text NOT NULL DEFAULT 'markdown',
    variables jsonb NOT NULL DEFAULT '[]',
    version   int NOT NULL DEFAULT 1,
    activo    boolean NOT NULL DEFAULT true
);

-- === Prompts del LLM =======================================================
-- El nodo del LLM toma sistema/usuario de la fila activa. Ajustar el prompt de
-- los 40 usuarios es INSERT de una versión nueva + UPDATE de activo.
CREATE TABLE prompts (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    servicio_codigo text NOT NULL REFERENCES servicios(codigo),
    version         int NOT NULL DEFAULT 1,
    sistema         text NOT NULL,
    usuario         text NOT NULL,           -- plantilla con {{hallazgos}} etc.
    modelo          text NOT NULL DEFAULT 'deepseek-chat',
    temperatura     numeric NOT NULL DEFAULT 0.2,
    max_tokens      int NOT NULL DEFAULT 2000,
    activo          boolean NOT NULL DEFAULT true
);
-- un solo prompt activo por servicio
CREATE UNIQUE INDEX uq_prompt_activo ON prompts(servicio_codigo) WHERE activo;

-- === Plantillas de PDF (HTML -> Gotenberg) =================================
CREATE TABLE plantillas_pdf (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    servicio_codigo text NOT NULL REFERENCES servicios(codigo),
    version         int NOT NULL DEFAULT 1,
    html            text NOT NULL,           -- con placeholders
    css             text NOT NULL DEFAULT '',
    activo          boolean NOT NULL DEFAULT true
);
CREATE UNIQUE INDEX uq_pdf_activo ON plantillas_pdf(servicio_codigo) WHERE activo;

-- === Parámetros por negocio (umbrales) =====================================
-- negocio_id NULL = default global; la fila del negocio lo pisa.
-- Un tendero de barrio y una ferretería no tienen los mismos umbrales.
CREATE TABLE parametros (
    negocio_id bigint REFERENCES negocios(id),
    clave      text NOT NULL,
    valor      jsonb NOT NULL
);
CREATE UNIQUE INDEX uq_param_negocio ON parametros(negocio_id, clave)
    WHERE negocio_id IS NOT NULL;
CREATE UNIQUE INDEX uq_param_global ON parametros(clave)
    WHERE negocio_id IS NULL;

-- Resuelve un parámetro: primero el del negocio, si no el global.
CREATE FUNCTION parametro(p_negocio_id bigint, p_clave text)
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT valor FROM parametros
    WHERE clave = p_clave
      AND (negocio_id = p_negocio_id OR negocio_id IS NULL)
    ORDER BY negocio_id NULLS LAST
    LIMIT 1;
$$;
