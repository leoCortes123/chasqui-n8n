
CREATE TABLE public.recomendaciones (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    regla text NOT NULL,
    clave_objeto text NOT NULL,
    titulo text NOT NULL,
    problema text,
    impacto text,
    impacto_mes numeric,
    impacto_tipo text,
    prioridad text,
    opciones jsonb DEFAULT '[]'::jsonb NOT NULL,
    origen_stock text,
    estado text DEFAULT 'nueva'::text NOT NULL,
    cerrada_por text,
    resultado text,
    detectada_en timestamp with time zone DEFAULT now() NOT NULL,
    vista_en timestamp with time zone,
    revisada_en timestamp with time zone DEFAULT now() NOT NULL,
    cerrada_en timestamp with time zone,
    veces_vista integer DEFAULT 0 NOT NULL,
    ejecucion_id bigint,
    datos jsonb DEFAULT '{}'::jsonb NOT NULL,
    icono text,
    CONSTRAINT recomendaciones_cerrada_por_check CHECK ((cerrada_por = ANY (ARRAY['dato'::text, 'accion_usuario'::text, 'sin_datos'::text]))),
    CONSTRAINT recomendaciones_check CHECK (((estado = ANY (ARRAY['nueva'::text, 'vigente'::text])) = (cerrada_en IS NULL))),
    CONSTRAINT recomendaciones_estado_check CHECK ((estado = ANY (ARRAY['nueva'::text, 'vigente'::text, 'resuelta'::text, 'ignorada'::text, 'caducada'::text]))),
    CONSTRAINT recomendaciones_resultado_check CHECK ((resultado = ANY (ARRAY['positivo'::text, 'neutro'::text, 'negativo'::text])))
);

ALTER TABLE public.recomendaciones ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.recomendaciones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY public.recomendaciones
    ADD CONSTRAINT recomendaciones_pkey PRIMARY KEY (id);

CREATE INDEX idx_recomendaciones_negocio ON public.recomendaciones USING btree (negocio_id, estado, detectada_en DESC);

CREATE UNIQUE INDEX uq_recomendacion_abierta ON public.recomendaciones USING btree (negocio_id, regla, clave_objeto) WHERE (estado = ANY (ARRAY['nueva'::text, 'vigente'::text]));

ALTER TABLE ONLY public.recomendaciones
    ADD CONSTRAINT recomendaciones_ejecucion_id_fkey FOREIGN KEY (ejecucion_id) REFERENCES public.ejecuciones(id);

ALTER TABLE ONLY public.recomendaciones
    ADD CONSTRAINT recomendaciones_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);

