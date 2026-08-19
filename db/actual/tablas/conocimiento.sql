
CREATE TABLE public.conocimiento (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    tipo text NOT NULL,
    clave text,
    titulo text NOT NULL,
    contenido text,
    datos jsonb DEFAULT '{}'::jsonb NOT NULL,
    origen text DEFAULT 'portal'::text NOT NULL,
    vigente_desde date DEFAULT CURRENT_DATE NOT NULL,
    vigente_hasta date,
    actualizado_en timestamp with time zone DEFAULT now() NOT NULL,
    actualizado_por bigint
);

ALTER TABLE public.conocimiento ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.conocimiento_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY public.conocimiento
    ADD CONSTRAINT conocimiento_pkey PRIMARY KEY (id);

CREATE INDEX idx_conocimiento_negocio ON public.conocimiento USING btree (negocio_id, tipo);

CREATE INDEX idx_conocimiento_texto_trgm ON public.conocimiento USING gin (public.norm_texto(((titulo || ' '::text) || COALESCE(contenido, ''::text))) public.gin_trgm_ops);

CREATE UNIQUE INDEX uq_conocimiento_clave ON public.conocimiento USING btree (negocio_id, tipo, clave) WHERE (clave IS NOT NULL);

ALTER TABLE ONLY public.conocimiento
    ADD CONSTRAINT conocimiento_actualizado_por_fkey FOREIGN KEY (actualizado_por) REFERENCES public.usuarios(id);

ALTER TABLE ONLY public.conocimiento
    ADD CONSTRAINT conocimiento_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);

