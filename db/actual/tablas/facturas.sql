
CREATE TABLE public.facturas (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    tercero_id bigint,
    documento_id bigint,
    tipo public.tipo_movimiento NOT NULL,
    numero text,
    emision date,
    vencimiento date,
    total numeric DEFAULT 0 NOT NULL,
    saldo numeric DEFAULT 0 NOT NULL,
    creado_en timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public.facturas ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.facturas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY public.facturas
    ADD CONSTRAINT facturas_documento_id_key UNIQUE (documento_id);

ALTER TABLE ONLY public.facturas
    ADD CONSTRAINT facturas_pkey PRIMARY KEY (id);

CREATE INDEX idx_facturas_abiertas ON public.facturas USING btree (negocio_id, vencimiento) WHERE (saldo > (0)::numeric);

ALTER TABLE ONLY public.facturas
    ADD CONSTRAINT facturas_documento_id_fkey FOREIGN KEY (documento_id) REFERENCES public.documentos(id);

ALTER TABLE ONLY public.facturas
    ADD CONSTRAINT facturas_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);

ALTER TABLE ONLY public.facturas
    ADD CONSTRAINT facturas_tercero_id_fkey FOREIGN KEY (tercero_id) REFERENCES public.terceros(id);

