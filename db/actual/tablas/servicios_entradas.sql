
CREATE TABLE public.servicios_entradas (
    servicio_codigo text NOT NULL,
    formato_codigo text NOT NULL,
    obligatorio boolean DEFAULT true NOT NULL,
    min_archivos integer DEFAULT 1 NOT NULL,
    max_archivos integer
);

ALTER TABLE ONLY public.servicios_entradas
    ADD CONSTRAINT servicios_entradas_pkey PRIMARY KEY (servicio_codigo, formato_codigo);

ALTER TABLE ONLY public.servicios_entradas
    ADD CONSTRAINT servicios_entradas_formato_codigo_fkey FOREIGN KEY (formato_codigo) REFERENCES public.formatos_documento(codigo);

ALTER TABLE ONLY public.servicios_entradas
    ADD CONSTRAINT servicios_entradas_servicio_codigo_fkey FOREIGN KEY (servicio_codigo) REFERENCES public.servicios(codigo);

