
CREATE TABLE public.sinonimos_columna (
    canonica text NOT NULL,
    patron text NOT NULL,
    prioridad integer DEFAULT 20 NOT NULL,
    CONSTRAINT sinonimos_canonica_valida CHECK ((canonica = ANY (ARRAY['fecha'::text, 'producto'::text, 'categoria'::text, 'cantidad'::text, 'valor_unitario'::text, 'valor_total'::text, 'codigo'::text, 'unidad'::text, 'impuesto'::text])))
);

ALTER TABLE ONLY public.sinonimos_columna
    ADD CONSTRAINT sinonimos_columna_pkey PRIMARY KEY (canonica, patron);

