
CREATE TABLE public.intenciones (
    codigo text NOT NULL,
    nombre text NOT NULL,
    patrones text[] NOT NULL,
    metrica text NOT NULL,
    periodo text DEFAULT 'todo'::text NOT NULL,
    filtros text[] DEFAULT '{}'::text[] NOT NULL,
    comparativo text,
    orden integer DEFAULT 100 NOT NULL,
    activo boolean DEFAULT true NOT NULL,
    CONSTRAINT intenciones_comparativo_check CHECK ((comparativo = ANY (ARRAY['periodo_anterior'::text, 'mismo_mes_ano_pasado'::text]))),
    CONSTRAINT intenciones_metrica_check CHECK ((metrica = ANY (ARRAY['ventas'::text, 'compras'::text, 'margen'::text, 'costo'::text, 'cobertura'::text, 'utilidad'::text, 'gasto_proveedor'::text]))),
    CONSTRAINT intenciones_periodo_check CHECK ((periodo = ANY (ARRAY['todo'::text, 'mes_actual'::text, 'mes_anterior'::text, 'ano_actual'::text, 'ultimos_30'::text])))
);

ALTER TABLE ONLY public.intenciones
    ADD CONSTRAINT intenciones_pkey PRIMARY KEY (codigo);

