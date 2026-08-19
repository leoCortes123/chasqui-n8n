
CREATE TABLE public.identidades (
    id bigint NOT NULL,
    canal text NOT NULL,
    id_externo text NOT NULL,
    usuario_id bigint NOT NULL,
    datos jsonb DEFAULT '{}'::jsonb NOT NULL,
    vista_en timestamp with time zone DEFAULT now() NOT NULL,
    creada_en timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public.identidades ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.identidades_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY public.identidades
    ADD CONSTRAINT identidades_canal_id_externo_key UNIQUE (canal, id_externo);

ALTER TABLE ONLY public.identidades
    ADD CONSTRAINT identidades_pkey PRIMARY KEY (id);

CREATE INDEX idx_identidades_usuario ON public.identidades USING btree (usuario_id);

ALTER TABLE ONLY public.identidades
    ADD CONSTRAINT identidades_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.usuarios(id) ON DELETE CASCADE;

