
CREATE TABLE public.negocios (
    id bigint NOT NULL,
    nombre text NOT NULL,
    nit text,
    tipo text,
    plan text DEFAULT 'free'::text NOT NULL,
    cupo_tokens_mes bigint DEFAULT 2000000 NOT NULL,
    creado_en timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public.negocios ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.negocios_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY public.negocios
    ADD CONSTRAINT negocios_pkey PRIMARY KEY (id);

