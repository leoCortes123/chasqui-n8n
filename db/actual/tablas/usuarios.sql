
CREATE TABLE public.usuarios (
    id bigint NOT NULL,
    negocio_id bigint,
    telegram_user_id bigint,
    telegram_chat_id bigint,
    telegram_username text,
    nombre text,
    rol public.rol_usuario DEFAULT 'operador'::public.rol_usuario NOT NULL,
    autorizacion_datos boolean DEFAULT false NOT NULL,
    autorizacion_fecha timestamp with time zone,
    creado_en timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public.usuarios ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.usuarios_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY public.usuarios
    ADD CONSTRAINT usuarios_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.usuarios
    ADD CONSTRAINT usuarios_telegram_user_id_key UNIQUE (telegram_user_id);

ALTER TABLE ONLY public.usuarios
    ADD CONSTRAINT usuarios_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);

