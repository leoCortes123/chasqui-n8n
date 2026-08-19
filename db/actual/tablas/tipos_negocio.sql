
CREATE TABLE public.tipos_negocio (
    codigo text NOT NULL,
    nombre text NOT NULL,
    orden integer DEFAULT 100 NOT NULL,
    activo boolean DEFAULT true NOT NULL
);

ALTER TABLE ONLY public.tipos_negocio
    ADD CONSTRAINT tipos_negocio_pkey PRIMARY KEY (codigo);

