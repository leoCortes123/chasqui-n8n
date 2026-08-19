
CREATE TABLE public.alertas_enviadas (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    regla text NOT NULL,
    clave_objeto text NOT NULL,
    prioridad text,
    titulo text,
    enviada_en timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public.alertas_enviadas ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.alertas_enviadas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY public.alertas_enviadas
    ADD CONSTRAINT alertas_enviadas_pkey PRIMARY KEY (id);

CREATE INDEX idx_alertas_cooldown ON public.alertas_enviadas USING btree (negocio_id, regla, clave_objeto, enviada_en DESC);

ALTER TABLE ONLY public.alertas_enviadas
    ADD CONSTRAINT alertas_enviadas_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);

