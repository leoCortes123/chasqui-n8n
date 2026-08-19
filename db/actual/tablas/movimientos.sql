
CREATE TABLE public.movimientos (
    id bigint NOT NULL,
    negocio_id bigint NOT NULL,
    documento_id bigint,
    tipo public.tipo_movimiento NOT NULL,
    fecha date,
    producto_id bigint,
    alias_id bigint,
    cantidad numeric,
    valor_unitario numeric,
    valor_total numeric,
    impuesto numeric DEFAULT 0,
    raw jsonb,
    creado_en timestamp with time zone DEFAULT now() NOT NULL,
    tercero_id bigint
);

ALTER TABLE public.movimientos ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.movimientos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);

ALTER TABLE ONLY public.movimientos
    ADD CONSTRAINT movimientos_pkey PRIMARY KEY (id);

CREATE INDEX idx_mov_documento ON public.movimientos USING btree (documento_id);

CREATE INDEX idx_mov_negocio_fecha ON public.movimientos USING btree (negocio_id, fecha);

CREATE INDEX idx_mov_producto ON public.movimientos USING btree (producto_id);

CREATE INDEX idx_mov_tercero ON public.movimientos USING btree (tercero_id);

CREATE TRIGGER trg_movimientos_limite_plan BEFORE INSERT ON public.movimientos FOR EACH ROW EXECUTE FUNCTION public.movimientos_limite_plan();

ALTER TABLE ONLY public.movimientos
    ADD CONSTRAINT movimientos_alias_id_fkey FOREIGN KEY (alias_id) REFERENCES public.alias(id);

ALTER TABLE ONLY public.movimientos
    ADD CONSTRAINT movimientos_documento_id_fkey FOREIGN KEY (documento_id) REFERENCES public.documentos(id);

ALTER TABLE ONLY public.movimientos
    ADD CONSTRAINT movimientos_negocio_id_fkey FOREIGN KEY (negocio_id) REFERENCES public.negocios(id);

ALTER TABLE ONLY public.movimientos
    ADD CONSTRAINT movimientos_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES public.productos(id);

ALTER TABLE ONLY public.movimientos
    ADD CONSTRAINT movimientos_tercero_id_fkey FOREIGN KEY (tercero_id) REFERENCES public.terceros(id);

