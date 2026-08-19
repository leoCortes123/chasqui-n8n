
CREATE TABLE public.plantillas (
    clave text NOT NULL,
    canal text DEFAULT 'telegram'::text NOT NULL,
    cuerpo text NOT NULL,
    formato text DEFAULT 'markdown'::text NOT NULL,
    variables jsonb DEFAULT '[]'::jsonb NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    activo boolean DEFAULT true NOT NULL,
    teclado jsonb DEFAULT '[]'::jsonb NOT NULL,
    crudas jsonb DEFAULT '[]'::jsonb NOT NULL,
    reemplaza boolean DEFAULT false NOT NULL
);

ALTER TABLE ONLY public.plantillas
    ADD CONSTRAINT plantillas_pkey PRIMARY KEY (clave);

