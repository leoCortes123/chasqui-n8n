
CREATE TABLE public.cotizaciones (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    creado_por bigint,
    cliente text,
    notas text,
    items jsonb DEFAULT '[]'::jsonb NOT NULL,
    total numeric DEFAULT 0 NOT NULL,
    token text NOT NULL,
    estado text DEFAULT 'abierta'::text NOT NULL,
    vigente_hasta date,
    creado_en timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public.cotizaciones ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.cotizaciones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY public.cotizaciones
    ADD CONSTRAINT cotizaciones_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.cotizaciones
    ADD CONSTRAINT cotizaciones_token_key UNIQUE (token);

CREATE INDEX idx_cotizaciones_negocio ON public.cotizaciones USING btree (negocio_id, creado_en DESC);

ALTER TABLE ONLY public.cotizaciones
    ADD CONSTRAINT cotizaciones_creado_por_fkey FOREIGN KEY (creado_por) REFERENCES public.usuarios(id);

ALTER TABLE ONLY public.cotizaciones
    ADD CONSTRAINT cotizaciones_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);

