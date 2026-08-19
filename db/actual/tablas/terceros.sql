
CREATE TABLE public.terceros (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    nit text,
    nombre text NOT NULL,
    creado_en timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public.terceros ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.terceros_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY public.terceros
    ADD CONSTRAINT terceros_pkey PRIMARY KEY (id);

CREATE UNIQUE INDEX idx_terceros_nit ON public.terceros USING btree (negocio_id, nit) WHERE (nit IS NOT NULL);

CREATE UNIQUE INDEX idx_terceros_nombre ON public.terceros USING btree (negocio_id, public.norm_texto(nombre)) WHERE (nit IS NULL);

ALTER TABLE ONLY public.terceros
    ADD CONSTRAINT terceros_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);

