
CREATE TABLE public.alias (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    texto_norm text NOT NULL,
    producto_id bigint,
    confianza numeric DEFAULT 1.0 NOT NULL,
    origen public.origen_alias DEFAULT 'pendiente'::public.origen_alias NOT NULL,
    creado_en timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public.alias ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.alias_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY public.alias
    ADD CONSTRAINT alias_negocio_id_texto_norm_key UNIQUE (negocio_id, texto_norm);

ALTER TABLE ONLY public.alias
    ADD CONSTRAINT alias_pkey PRIMARY KEY (id);

CREATE INDEX idx_alias_pendientes ON public.alias USING btree (negocio_id) WHERE (producto_id IS NULL);

CREATE INDEX idx_alias_texto_trgm ON public.alias USING gin (texto_norm public.gin_trgm_ops);

ALTER TABLE ONLY public.alias
    ADD CONSTRAINT alias_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);

ALTER TABLE ONLY public.alias
    ADD CONSTRAINT alias_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES public.productos(id);

