
CREATE TABLE public.prompts_tecnicos (
    clave text NOT NULL,
    sistema text NOT NULL,
    usuario text NOT NULL,
    modelo text DEFAULT 'deepseek-v4-flash'::text NOT NULL,
    temperatura numeric DEFAULT 0.0 NOT NULL,
    max_tokens integer DEFAULT 800 NOT NULL,
    activo boolean DEFAULT true NOT NULL
);

ALTER TABLE ONLY public.prompts_tecnicos
    ADD CONSTRAINT prompts_tecnicos_pkey PRIMARY KEY (clave);

