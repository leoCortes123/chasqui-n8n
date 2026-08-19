
CREATE TABLE public.snapshots_negocio (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    fecha date DEFAULT CURRENT_DATE NOT NULL,
    version integer NOT NULL,
    periodo daterange,
    salud jsonb,
    metricas jsonb NOT NULL,
    origen text NOT NULL,
    ejecucion_id bigint,
    creado_en timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE public.snapshots_negocio ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.snapshots_negocio_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY public.snapshots_negocio
    ADD CONSTRAINT snapshots_negocio_pkey PRIMARY KEY (id);

ALTER TABLE ONLY public.snapshots_negocio
    ADD CONSTRAINT uq_snapshot_dia UNIQUE (negocio_id, fecha);

CREATE INDEX idx_snapshots_negocio_fecha ON public.snapshots_negocio USING btree (negocio_id, fecha DESC);

ALTER TABLE ONLY public.snapshots_negocio
    ADD CONSTRAINT snapshots_negocio_ejecucion_id_fkey FOREIGN KEY (ejecucion_id) REFERENCES public.ejecuciones(id);

ALTER TABLE ONLY public.snapshots_negocio
    ADD CONSTRAINT snapshots_negocio_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);

