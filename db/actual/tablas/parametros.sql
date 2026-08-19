
CREATE TABLE public.parametros (
    negocio_id bigint,
    clave text NOT NULL,
    valor jsonb NOT NULL
);

CREATE UNIQUE INDEX uq_param_global ON public.parametros USING btree (clave) WHERE (negocio_id IS NULL);

CREATE UNIQUE INDEX uq_param_negocio ON public.parametros USING btree (negocio_id, clave) WHERE (negocio_id IS NOT NULL);

ALTER TABLE ONLY public.parametros
    ADD CONSTRAINT parametros_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);

