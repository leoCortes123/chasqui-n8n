
CREATE TABLE public.prompts (
    id bigint NOT NULL,
    servicio_codigo text NOT NULL,
    version integer DEFAULT 1 NOT NULL,
    sistema text NOT NULL,
    usuario text NOT NULL,
    modelo text DEFAULT 'deepseek-v4-flash'::text NOT NULL,
    temperatura numeric DEFAULT 0.2 NOT NULL,
    max_tokens integer DEFAULT 2000 NOT NULL,
    activo boolean DEFAULT true NOT NULL
);

ALTER TABLE public.prompts ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.prompts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY public.prompts
    ADD CONSTRAINT prompts_pkey PRIMARY KEY (id);

CREATE UNIQUE INDEX uq_prompt_activo ON public.prompts USING btree (servicio_codigo) WHERE activo;

ALTER TABLE ONLY public.prompts
    ADD CONSTRAINT prompts_servicio_codigo_fkey FOREIGN KEY (servicio_codigo) REFERENCES public.servicios(codigo);

