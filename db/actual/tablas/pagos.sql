
CREATE TABLE public.pagos (
    id bigint NOT NULL,
    factura_id bigint NOT NULL,
    fecha date DEFAULT CURRENT_DATE NOT NULL,
    valor numeric NOT NULL,
    medio text,
    origen text DEFAULT 'portal'::text NOT NULL,
    usuario_id bigint,
    creado_en timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public.pagos ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.pagos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY public.pagos
    ADD CONSTRAINT pagos_pkey PRIMARY KEY (id);

CREATE INDEX idx_pagos_factura ON public.pagos USING btree (factura_id);

ALTER TABLE ONLY public.pagos
    ADD CONSTRAINT pagos_factura_id_fkey FOREIGN KEY (factura_id) REFERENCES public.facturas(id);

ALTER TABLE ONLY public.pagos
    ADD CONSTRAINT pagos_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.usuarios(id);

