
CREATE TABLE public.portal_tokens (
    id bigint NOT NULL,
    usuario_id bigint NOT NULL,
    hash bytea NOT NULL,
    expira_en timestamp with time zone NOT NULL,
    usado_en timestamp with time zone,
    creado_en timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public.portal_tokens ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.portal_tokens_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY public.portal_tokens
    ADD CONSTRAINT portal_tokens_hash_key UNIQUE (hash);

ALTER TABLE ONLY public.portal_tokens
    ADD CONSTRAINT portal_tokens_pkey PRIMARY KEY (id);

CREATE INDEX idx_portal_tokens_vivos ON public.portal_tokens USING btree (expira_en) WHERE (usado_en IS NULL);

ALTER TABLE ONLY public.portal_tokens
    ADD CONSTRAINT portal_tokens_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.usuarios(id) ON DELETE CASCADE;

