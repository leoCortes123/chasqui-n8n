
CREATE TABLE public.conteos_inventario (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    producto_id bigint NOT NULL,
    fecha date NOT NULL,
    unidades numeric NOT NULL,
    origen text DEFAULT 'portal'::text NOT NULL,
    documento_id bigint,
    nota text,
    creado_en timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT conteos_inventario_origen_check CHECK ((origen = ANY (ARRAY['portal'::text, 'archivo'::text, 'chat'::text]))),
    CONSTRAINT conteos_inventario_unidades_check CHECK ((unidades >= (0)::numeric))
);

ALTER TABLE public.conteos_inventario ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.conteos_inventario_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY public.conteos_inventario
    ADD CONSTRAINT conteos_inventario_negocio_id_producto_id_fecha_key UNIQUE (negocio_id, producto_id, fecha);

ALTER TABLE ONLY public.conteos_inventario
    ADD CONSTRAINT conteos_inventario_pkey PRIMARY KEY (id);

CREATE INDEX idx_conteos_prod ON public.conteos_inventario USING btree (negocio_id, producto_id, fecha DESC);

ALTER TABLE ONLY public.conteos_inventario
    ADD CONSTRAINT conteos_inventario_documento_id_fkey FOREIGN KEY (documento_id) REFERENCES public.documentos(id);

ALTER TABLE ONLY public.conteos_inventario
    ADD CONSTRAINT conteos_inventario_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);

ALTER TABLE ONLY public.conteos_inventario
    ADD CONSTRAINT conteos_inventario_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES public.productos(id);

