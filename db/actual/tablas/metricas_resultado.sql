
CREATE TABLE public.metricas_resultado (
    regla text NOT NULL,
    metrica text NOT NULL,
    direccion text NOT NULL,
    umbral_pct numeric DEFAULT 5 NOT NULL,
    CONSTRAINT metricas_resultado_direccion_check CHECK ((direccion = ANY (ARRAY['sube_mejor'::text, 'baja_mejor'::text]))),
    CONSTRAINT metricas_resultado_metrica_check CHECK ((metrica = ANY (ARRAY['costo'::text, 'margen_pct'::text, 'dias_cobertura'::text, 'balance'::text, 'concentracion_pct'::text, 'unidades_vendidas'::text, 'ventas'::text, 'saldo_vencido'::text])))
);

ALTER TABLE ONLY public.metricas_resultado
    ADD CONSTRAINT metricas_resultado_pkey PRIMARY KEY (regla);

