
CREATE TABLE public.servicios (
    codigo text NOT NULL,
    nombre text NOT NULL,
    descripcion text,
    orden integer DEFAULT 100 NOT NULL,
    activo boolean DEFAULT true NOT NULL,
    funcion_hallazgos text DEFAULT 'hallazgos_generar'::text NOT NULL,
    entrada text DEFAULT 'archivos'::text NOT NULL,
    modulo_codigo text,
    CONSTRAINT servicios_entrada_ck CHECK ((entrada = ANY (ARRAY['archivos'::text, 'texto'::text])))
);

ALTER TABLE ONLY public.servicios
    ADD CONSTRAINT servicios_pkey PRIMARY KEY (codigo);

ALTER TABLE ONLY public.servicios
    ADD CONSTRAINT servicios_modulo_codigo_fkey FOREIGN KEY (modulo_codigo) REFERENCES public.modulos(codigo);

