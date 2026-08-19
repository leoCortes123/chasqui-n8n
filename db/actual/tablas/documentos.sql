
CREATE TABLE public.documentos (
    id bigint NOT NULL,
    sesion_id bigint,
    negocio_id bigint NOT NULL,
    formato_codigo text,
    nombre_archivo text,
    mime text,
    hash bytea NOT NULL,
    contenido bytea NOT NULL,
    tamano bigint,
    estado public.estado_doc DEFAULT 'pendiente'::public.estado_doc NOT NULL,
    error text,
    creado_en timestamp with time zone DEFAULT now() NOT NULL,
    filas_fuera_de_plan integer DEFAULT 0 NOT NULL,
    motivo_pendiente text
);

ALTER TABLE public.documentos ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.documentos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY public.documentos
    ADD CONSTRAINT documentos_negocio_id_hash_key UNIQUE (negocio_id, hash);

ALTER TABLE ONLY public.documentos
    ADD CONSTRAINT documentos_pkey PRIMARY KEY (id);

CREATE INDEX idx_documentos_sesion ON public.documentos USING btree (sesion_id);

ALTER TABLE ONLY public.documentos
    ADD CONSTRAINT documentos_formato_codigo_fkey FOREIGN KEY (formato_codigo) REFERENCES public.formatos_documento(codigo);

ALTER TABLE ONLY public.documentos
    ADD CONSTRAINT documentos_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);

ALTER TABLE ONLY public.documentos
    ADD CONSTRAINT documentos_sesion_id_fkey FOREIGN KEY (sesion_id) REFERENCES public.sesiones(id);

