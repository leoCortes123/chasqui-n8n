
CREATE TABLE public.formatos_documento (
    codigo text NOT NULL,
    nombre text NOT NULL,
    mime_patrones text[] DEFAULT '{}'::text[] NOT NULL,
    extensiones text[] DEFAULT '{}'::text[] NOT NULL,
    funcion_parseo text NOT NULL,
    deteccion jsonb DEFAULT '{}'::jsonb NOT NULL,
    mapeo jsonb DEFAULT '{}'::jsonb NOT NULL,
    activo boolean DEFAULT true NOT NULL,
    clase text DEFAULT 'documento'::text NOT NULL,
    huella text,
    origen text DEFAULT 'semilla'::text NOT NULL,
    CONSTRAINT formatos_documento_clase_check CHECK ((clase = ANY (ARRAY['documento'::text, 'tabular'::text]))),
    CONSTRAINT formatos_documento_origen_check CHECK ((origen = ANY (ARRAY['semilla'::text, 'inferido'::text])))
);

ALTER TABLE ONLY public.formatos_documento
    ADD CONSTRAINT formatos_documento_pkey PRIMARY KEY (codigo);

CREATE UNIQUE INDEX uq_formato_huella ON public.formatos_documento USING btree (huella) WHERE (huella IS NOT NULL);

