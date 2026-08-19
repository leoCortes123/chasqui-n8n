
CREATE TABLE public.modulos (
    codigo text NOT NULL,
    nombre text NOT NULL,
    titular text NOT NULL,
    ayuda text NOT NULL,
    orden integer DEFAULT 100 NOT NULL,
    activo boolean DEFAULT true NOT NULL
);

ALTER TABLE ONLY public.modulos
    ADD CONSTRAINT modulos_pkey PRIMARY KEY (codigo);

