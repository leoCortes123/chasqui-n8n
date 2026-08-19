
CREATE TABLE public.conocimiento_pendiente (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    pregunta text NOT NULL,
    pregunta_norm text NOT NULL,
    veces integer DEFAULT 1 NOT NULL,
    resuelto_por bigint,
    primera_en timestamp with time zone DEFAULT now() NOT NULL,
    ultima_en timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public.conocimiento_pendiente ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.conocimiento_pendiente_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY public.conocimiento_pendiente
    ADD CONSTRAINT conocimiento_pendiente_negocio_id_pregunta_norm_key UNIQUE (negocio_id, pregunta_norm);

ALTER TABLE ONLY public.conocimiento_pendiente
    ADD CONSTRAINT conocimiento_pendiente_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.conocimiento_pendiente
    ADD CONSTRAINT conocimiento_pendiente_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);

ALTER TABLE ONLY public.conocimiento_pendiente
    ADD CONSTRAINT conocimiento_pendiente_resuelto_por_fkey FOREIGN KEY (resuelto_por) REFERENCES public.conocimiento(id);

