
CREATE TABLE public.schema_migraciones (
    archivo text NOT NULL,
    aplicada_en timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE ONLY public.schema_migraciones
    ADD CONSTRAINT schema_migraciones_pkey PRIMARY KEY (archivo);

