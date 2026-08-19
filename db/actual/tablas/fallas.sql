
CREATE TABLE public.fallas (
    id bigint NOT NULL,
    workflow text,
    ejecucion_id bigint,
    sesion_id bigint,
    tipo text,
    transitoria boolean DEFAULT false NOT NULL,
    intentos integer DEFAULT 0 NOT NULL,
    detalle jsonb,
    creada_en timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public.fallas ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.fallas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY public.fallas
    ADD CONSTRAINT fallas_pkey PRIMARY KEY (id);

CREATE INDEX idx_fallas_recientes ON public.fallas USING btree (creada_en);

ALTER TABLE ONLY public.fallas
    ADD CONSTRAINT fallas_ejecucion_id_fkey FOREIGN KEY (ejecucion_id) REFERENCES public.ejecuciones(id);

ALTER TABLE ONLY public.fallas
    ADD CONSTRAINT fallas_sesion_id_fkey FOREIGN KEY (sesion_id) REFERENCES public.sesiones(id);

