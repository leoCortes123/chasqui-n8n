
CREATE TABLE public.productos (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    nombre_canonico text NOT NULL,
    unidad text,
    categoria text,
    creado_en timestamp with time zone DEFAULT now() NOT NULL,
    codigo_barras text
);

ALTER TABLE public.productos ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.productos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY public.productos
    ADD CONSTRAINT productos_pkey PRIMARY KEY (id);

CREATE INDEX idx_productos_negocio ON public.productos USING btree (negocio_id);

CREATE INDEX idx_productos_nombre_trgm ON public.productos USING gin (nombre_canonico public.gin_trgm_ops);

CREATE UNIQUE INDEX uq_producto_barras ON public.productos USING btree (negocio_id, codigo_barras) WHERE (codigo_barras IS NOT NULL);

ALTER TABLE ONLY public.productos
    ADD CONSTRAINT productos_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);

