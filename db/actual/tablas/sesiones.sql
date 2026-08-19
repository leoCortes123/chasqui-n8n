
CREATE TABLE public.sesiones (
    id bigint NOT NULL,
    usuario_id bigint NOT NULL,
    negocio_id bigint,
    servicio_codigo text,
    paso text,
    estado public.estado_sesion DEFAULT 'intake'::public.estado_sesion NOT NULL,
    contexto jsonb DEFAULT '{}'::jsonb NOT NULL,
    ultima_actividad timestamp with time zone DEFAULT now() NOT NULL,
    creada_en timestamp with time zone DEFAULT now() NOT NULL,
    cerrada_en timestamp with time zone,
    panel_mensaje_id bigint,
    analisis_pedido_en timestamp with time zone,
    panel_pedido_en timestamp with time zone
);

ALTER TABLE public.sesiones ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.sesiones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY public.sesiones
    ADD CONSTRAINT sesiones_pkey PRIMARY KEY (id);

CREATE INDEX idx_sesiones_actividad ON public.sesiones USING btree (ultima_actividad) WHERE (cerrada_en IS NULL);

CREATE INDEX idx_sesiones_usuario ON public.sesiones USING btree (usuario_id) WHERE (cerrada_en IS NULL);

ALTER TABLE ONLY public.sesiones
    ADD CONSTRAINT sesiones_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);

ALTER TABLE ONLY public.sesiones
    ADD CONSTRAINT sesiones_servicio_codigo_fkey FOREIGN KEY (servicio_codigo) REFERENCES public.servicios(codigo);

ALTER TABLE ONLY public.sesiones
    ADD CONSTRAINT sesiones_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES public.usuarios(id);

