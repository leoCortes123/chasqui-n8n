
CREATE TABLE public.ejecuciones (
    id bigint NOT NULL,
    sesion_id bigint,
    negocio_id bigint NOT NULL,
    servicio_codigo text,
    estado public.estado_ejec DEFAULT 'preparando'::public.estado_ejec NOT NULL,
    prompt_id bigint,
    hallazgos jsonb,
    texto text,
    pdf bytea,
    tokens_prompt integer DEFAULT 0,
    tokens_salida integer DEFAULT 0,
    costo numeric DEFAULT 0,
    error text,
    inicio timestamp with time zone DEFAULT now() NOT NULL,
    fin timestamp with time zone
);

ALTER TABLE public.ejecuciones ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.ejecuciones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY public.ejecuciones
    ADD CONSTRAINT ejecuciones_pkey PRIMARY KEY (id);

CREATE INDEX idx_ejec_colgadas ON public.ejecuciones USING btree (inicio) WHERE (estado = ANY (ARRAY['preparando'::public.estado_ejec, 'procesando'::public.estado_ejec, 'validando'::public.estado_ejec]));

CREATE INDEX idx_ejec_negocio ON public.ejecuciones USING btree (negocio_id, inicio);

ALTER TABLE ONLY public.ejecuciones
    ADD CONSTRAINT ejecuciones_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);

ALTER TABLE ONLY public.ejecuciones
    ADD CONSTRAINT ejecuciones_servicio_codigo_fkey FOREIGN KEY (servicio_codigo) REFERENCES public.servicios(codigo);

ALTER TABLE ONLY public.ejecuciones
    ADD CONSTRAINT ejecuciones_sesion_id_fkey FOREIGN KEY (sesion_id) REFERENCES public.sesiones(id);

