--
-- PostgreSQL database dump
--

\restrict JZI3C2EGxuVGCnEuaYaLYpPR5g663HOH8fG6HNzQWCcr8ZN054luTzt8T5I9G1J

-- Dumped from database version 16.14 (Debian 16.14-1.pgdg13+1)
-- Dumped by pg_dump version 16.14 (Debian 16.14-1.pgdg13+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

ALTER TABLE IF EXISTS ONLY public.ventas DROP CONSTRAINT IF EXISTS ventas_telegram_user_id_fkey;
ALTER TABLE IF EXISTS ONLY public.ventas DROP CONSTRAINT IF EXISTS ventas_carga_id_fkey;
ALTER TABLE IF EXISTS ONLY public.cargas DROP CONSTRAINT IF EXISTS cargas_telegram_user_id_fkey;
DROP INDEX IF EXISTS public.idx_ventas_user;
ALTER TABLE IF EXISTS ONLY public.ventas DROP CONSTRAINT IF EXISTS ventas_pkey;
ALTER TABLE IF EXISTS ONLY public.usuarios DROP CONSTRAINT IF EXISTS usuarios_pkey;
ALTER TABLE IF EXISTS ONLY public.cargas DROP CONSTRAINT IF EXISTS cargas_pkey;
ALTER TABLE IF EXISTS public.ventas ALTER COLUMN id DROP DEFAULT;
ALTER TABLE IF EXISTS public.cargas ALTER COLUMN id DROP DEFAULT;
DROP SEQUENCE IF EXISTS public.ventas_id_seq;
DROP TABLE IF EXISTS public.ventas;
DROP TABLE IF EXISTS public.usuarios;
DROP SEQUENCE IF EXISTS public.cargas_id_seq;
DROP TABLE IF EXISTS public.cargas;
SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: cargas; Type: TABLE; Schema: public; Owner: botpymes
--

CREATE TABLE public.cargas (
    id bigint NOT NULL,
    telegram_user_id bigint,
    file_name text,
    formato text,
    filas integer,
    uploaded_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.cargas OWNER TO botpymes;

--
-- Name: cargas_id_seq; Type: SEQUENCE; Schema: public; Owner: botpymes
--

CREATE SEQUENCE public.cargas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.cargas_id_seq OWNER TO botpymes;

--
-- Name: cargas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: botpymes
--

ALTER SEQUENCE public.cargas_id_seq OWNED BY public.cargas.id;


--
-- Name: usuarios; Type: TABLE; Schema: public; Owner: botpymes
--

CREATE TABLE public.usuarios (
    telegram_user_id bigint NOT NULL,
    telegram_username text,
    sistema_origen text,
    negocio_nombre text,
    plan text DEFAULT 'free'::text,
    reportes_usados integer DEFAULT 0,
    autorizacion_datos boolean DEFAULT false,
    autorizacion_fecha timestamp with time zone,
    created_at timestamp with time zone DEFAULT now()
);


ALTER TABLE public.usuarios OWNER TO botpymes;

--
-- Name: ventas; Type: TABLE; Schema: public; Owner: botpymes
--

CREATE TABLE public.ventas (
    id bigint NOT NULL,
    carga_id bigint,
    telegram_user_id bigint,
    fecha date,
    producto text,
    categoria text,
    cantidad numeric,
    precio_unitario numeric,
    total numeric,
    raw jsonb
);


ALTER TABLE public.ventas OWNER TO botpymes;

--
-- Name: ventas_id_seq; Type: SEQUENCE; Schema: public; Owner: botpymes
--

CREATE SEQUENCE public.ventas_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.ventas_id_seq OWNER TO botpymes;

--
-- Name: ventas_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: botpymes
--

ALTER SEQUENCE public.ventas_id_seq OWNED BY public.ventas.id;


--
-- Name: cargas id; Type: DEFAULT; Schema: public; Owner: botpymes
--

ALTER TABLE ONLY public.cargas ALTER COLUMN id SET DEFAULT nextval('public.cargas_id_seq'::regclass);


--
-- Name: ventas id; Type: DEFAULT; Schema: public; Owner: botpymes
--

ALTER TABLE ONLY public.ventas ALTER COLUMN id SET DEFAULT nextval('public.ventas_id_seq'::regclass);


--
-- Data for Name: cargas; Type: TABLE DATA; Schema: public; Owner: botpymes
--

COPY public.cargas (id, telegram_user_id, file_name, formato, filas, uploaded_at) FROM stdin;
0	7815282144	plantilla_ventas.csv	csv	1	2026-07-23 14:02:28.305614-05
1	7815282144	plantilla_ventas.csv	csv	1	2026-07-23 14:07:35.690522-05
2	7815282144	plantilla_ventas.csv	csv	1	2026-07-23 14:07:53.13725-05
3	7815282144	plantilla_ventas.csv	csv	1	2026-07-23 14:09:39.453798-05
4	7815282144	plantilla_ventas.csv	csv	1	2026-07-23 17:48:38.996675-05
5	7815282144	plantilla_ventas.csv	csv	1	2026-07-23 17:58:45.698691-05
6	7815282144	plantilla_ventas.csv	csv	1	2026-07-23 18:12:41.163478-05
7	7815282144	plantilla_ventas.csv	csv	1	2026-07-23 18:33:35.800207-05
8	7815282144	plantilla_ventas.csv	csv	15	2026-07-23 19:25:09.916119-05
9	7815282144	plantilla_ventas.csv	csv	15	2026-07-23 19:30:20.335897-05
10	7815282144	plantilla_ventas.csv	csv	15	2026-07-23 20:02:02.990534-05
\.


--
-- Data for Name: usuarios; Type: TABLE DATA; Schema: public; Owner: botpymes
--

COPY public.usuarios (telegram_user_id, telegram_username, sistema_origen, negocio_nombre, plan, reportes_usados, autorizacion_datos, autorizacion_fecha, created_at) FROM stdin;
7815282144	\N	\N	\N	free	0	f	\N	2026-07-23 13:58:09.324681-05
\.


--
-- Data for Name: ventas; Type: TABLE DATA; Schema: public; Owner: botpymes
--

COPY public.ventas (id, carga_id, telegram_user_id, fecha, producto, categoria, cantidad, precio_unitario, total, raw) FROM stdin;
1	5	7815282144	2026-07-01	Arroz Diana 500g	Granos	3	2500	7500	\N
2	5	7815282144	2026-07-01	Gaseosa Postobón 1.5L	Bebidas	2	4500	9000	\N
3	5	7815282144	2026-07-02	Leche Alquería 1L	Lácteos	5	3800	19000	\N
4	5	7815282144	2026-07-02	Pan Bimbo tajado	Panadería	1	6200	6200	\N
5	5	7815282144	2026-07-03	Aceite Gourmet 1L	Abarrotes	2	9500	19000	\N
6	5	7815282144	2026-07-03	Huevos AA x30	Lácteos	1	15000	15000	\N
7	5	7815282144	2026-07-04	Café Águila Roja 500g	Abarrotes	1	11800	11800	\N
8	5	7815282144	2026-07-04	Azúcar Manuelita 1kg	Granos	4	3200	12800	\N
9	5	7815282144	2026-07-05	Cerveza Águila 330ml	Bebidas	6	2200	13200	\N
10	5	7815282144	2026-07-05	Jabón Rey 300g	Aseo	3	2100	6300	\N
11	5	7815282144	2026-07-06	Papel Higiénico Familia x6	Aseo	2	8900	17800	\N
12	5	7815282144	2026-07-06	Chocolate Jet	Snacks	10	900	9000	\N
13	5	7815282144	2026-07-07	Atún Van Camps	Enlatados	3	4700	14100	\N
14	5	7815282144	2026-07-07	Yogurt Alpina 1L	Lácteos	2	7200	14400	\N
15	5	7815282144	2026-07-08	Salchichas Zenú	Embutidos	2	6800	13600	\N
16	6	7815282144	2026-07-01	Arroz Diana 500g	Granos	3	2500	7500	\N
17	6	7815282144	2026-07-01	Gaseosa Postobón 1.5L	Bebidas	2	4500	9000	\N
18	6	7815282144	2026-07-02	Leche Alquería 1L	Lácteos	5	3800	19000	\N
19	6	7815282144	2026-07-02	Pan Bimbo tajado	Panadería	1	6200	6200	\N
20	6	7815282144	2026-07-03	Aceite Gourmet 1L	Abarrotes	2	9500	19000	\N
21	6	7815282144	2026-07-03	Huevos AA x30	Lácteos	1	15000	15000	\N
22	6	7815282144	2026-07-04	Café Águila Roja 500g	Abarrotes	1	11800	11800	\N
23	6	7815282144	2026-07-04	Azúcar Manuelita 1kg	Granos	4	3200	12800	\N
24	6	7815282144	2026-07-05	Cerveza Águila 330ml	Bebidas	6	2200	13200	\N
25	6	7815282144	2026-07-05	Jabón Rey 300g	Aseo	3	2100	6300	\N
26	6	7815282144	2026-07-06	Papel Higiénico Familia x6	Aseo	2	8900	17800	\N
27	6	7815282144	2026-07-06	Chocolate Jet	Snacks	10	900	9000	\N
28	6	7815282144	2026-07-07	Atún Van Camps	Enlatados	3	4700	14100	\N
29	6	7815282144	2026-07-07	Yogurt Alpina 1L	Lácteos	2	7200	14400	\N
30	6	7815282144	2026-07-08	Salchichas Zenú	Embutidos	2	6800	13600	\N
31	7	7815282144	2026-07-01	Arroz Diana 500g	Granos	3	2500	7500	\N
32	7	7815282144	2026-07-01	Gaseosa Postobón 1.5L	Bebidas	2	4500	9000	\N
33	7	7815282144	2026-07-02	Leche Alquería 1L	Lácteos	5	3800	19000	\N
34	7	7815282144	2026-07-02	Pan Bimbo tajado	Panadería	1	6200	6200	\N
35	7	7815282144	2026-07-03	Aceite Gourmet 1L	Abarrotes	2	9500	19000	\N
36	7	7815282144	2026-07-03	Huevos AA x30	Lácteos	1	15000	15000	\N
37	7	7815282144	2026-07-04	Café Águila Roja 500g	Abarrotes	1	11800	11800	\N
38	7	7815282144	2026-07-04	Azúcar Manuelita 1kg	Granos	4	3200	12800	\N
39	7	7815282144	2026-07-05	Cerveza Águila 330ml	Bebidas	6	2200	13200	\N
40	7	7815282144	2026-07-05	Jabón Rey 300g	Aseo	3	2100	6300	\N
41	7	7815282144	2026-07-06	Papel Higiénico Familia x6	Aseo	2	8900	17800	\N
42	7	7815282144	2026-07-06	Chocolate Jet	Snacks	10	900	9000	\N
43	7	7815282144	2026-07-07	Atún Van Camps	Enlatados	3	4700	14100	\N
44	7	7815282144	2026-07-07	Yogurt Alpina 1L	Lácteos	2	7200	14400	\N
45	7	7815282144	2026-07-08	Salchichas Zenú	Embutidos	2	6800	13600	\N
46	8	7815282144	2026-07-01	Arroz Diana 500g	Granos	3	2500	7500	\N
47	8	7815282144	2026-07-01	Gaseosa Postobón 1.5L	Bebidas	2	4500	9000	\N
48	8	7815282144	2026-07-02	Leche Alquería 1L	Lácteos	5	3800	19000	\N
49	8	7815282144	2026-07-02	Pan Bimbo tajado	Panadería	1	6200	6200	\N
50	8	7815282144	2026-07-03	Aceite Gourmet 1L	Abarrotes	2	9500	19000	\N
51	8	7815282144	2026-07-03	Huevos AA x30	Lácteos	1	15000	15000	\N
52	8	7815282144	2026-07-04	Café Águila Roja 500g	Abarrotes	1	11800	11800	\N
53	8	7815282144	2026-07-04	Azúcar Manuelita 1kg	Granos	4	3200	12800	\N
54	8	7815282144	2026-07-05	Cerveza Águila 330ml	Bebidas	6	2200	13200	\N
55	8	7815282144	2026-07-05	Jabón Rey 300g	Aseo	3	2100	6300	\N
56	8	7815282144	2026-07-06	Papel Higiénico Familia x6	Aseo	2	8900	17800	\N
57	8	7815282144	2026-07-06	Chocolate Jet	Snacks	10	900	9000	\N
58	8	7815282144	2026-07-07	Atún Van Camps	Enlatados	3	4700	14100	\N
59	8	7815282144	2026-07-07	Yogurt Alpina 1L	Lácteos	2	7200	14400	\N
60	8	7815282144	2026-07-08	Salchichas Zenú	Embutidos	2	6800	13600	\N
61	9	7815282144	2026-07-01	Arroz Diana 500g	Granos	3	2500	7500	\N
62	9	7815282144	2026-07-01	Gaseosa Postobón 1.5L	Bebidas	2	4500	9000	\N
63	9	7815282144	2026-07-02	Leche Alquería 1L	Lácteos	5	3800	19000	\N
64	9	7815282144	2026-07-02	Pan Bimbo tajado	Panadería	1	6200	6200	\N
65	9	7815282144	2026-07-03	Aceite Gourmet 1L	Abarrotes	2	9500	19000	\N
66	9	7815282144	2026-07-03	Huevos AA x30	Lácteos	1	15000	15000	\N
67	9	7815282144	2026-07-04	Café Águila Roja 500g	Abarrotes	1	11800	11800	\N
68	9	7815282144	2026-07-04	Azúcar Manuelita 1kg	Granos	4	3200	12800	\N
69	9	7815282144	2026-07-05	Cerveza Águila 330ml	Bebidas	6	2200	13200	\N
70	9	7815282144	2026-07-05	Jabón Rey 300g	Aseo	3	2100	6300	\N
71	9	7815282144	2026-07-06	Papel Higiénico Familia x6	Aseo	2	8900	17800	\N
72	9	7815282144	2026-07-06	Chocolate Jet	Snacks	10	900	9000	\N
73	9	7815282144	2026-07-07	Atún Van Camps	Enlatados	3	4700	14100	\N
74	9	7815282144	2026-07-07	Yogurt Alpina 1L	Lácteos	2	7200	14400	\N
75	9	7815282144	2026-07-08	Salchichas Zenú	Embutidos	2	6800	13600	\N
76	10	7815282144	2026-07-01	Arroz Diana 500g	Granos	3	2500	7500	\N
77	10	7815282144	2026-07-01	Gaseosa Postobón 1.5L	Bebidas	2	4500	9000	\N
78	10	7815282144	2026-07-02	Leche Alquería 1L	Lácteos	5	3800	19000	\N
79	10	7815282144	2026-07-02	Pan Bimbo tajado	Panadería	1	6200	6200	\N
80	10	7815282144	2026-07-03	Aceite Gourmet 1L	Abarrotes	2	9500	19000	\N
81	10	7815282144	2026-07-03	Huevos AA x30	Lácteos	1	15000	15000	\N
82	10	7815282144	2026-07-04	Café Águila Roja 500g	Abarrotes	1	11800	11800	\N
83	10	7815282144	2026-07-04	Azúcar Manuelita 1kg	Granos	4	3200	12800	\N
84	10	7815282144	2026-07-05	Cerveza Águila 330ml	Bebidas	6	2200	13200	\N
85	10	7815282144	2026-07-05	Jabón Rey 300g	Aseo	3	2100	6300	\N
86	10	7815282144	2026-07-06	Papel Higiénico Familia x6	Aseo	2	8900	17800	\N
87	10	7815282144	2026-07-06	Chocolate Jet	Snacks	10	900	9000	\N
88	10	7815282144	2026-07-07	Atún Van Camps	Enlatados	3	4700	14100	\N
89	10	7815282144	2026-07-07	Yogurt Alpina 1L	Lácteos	2	7200	14400	\N
90	10	7815282144	2026-07-08	Salchichas Zenú	Embutidos	2	6800	13600	\N
\.


--
-- Name: cargas_id_seq; Type: SEQUENCE SET; Schema: public; Owner: botpymes
--

SELECT pg_catalog.setval('public.cargas_id_seq', 10, true);


--
-- Name: ventas_id_seq; Type: SEQUENCE SET; Schema: public; Owner: botpymes
--

SELECT pg_catalog.setval('public.ventas_id_seq', 90, true);


--
-- Name: cargas cargas_pkey; Type: CONSTRAINT; Schema: public; Owner: botpymes
--

ALTER TABLE ONLY public.cargas
    ADD CONSTRAINT cargas_pkey PRIMARY KEY (id);


--
-- Name: usuarios usuarios_pkey; Type: CONSTRAINT; Schema: public; Owner: botpymes
--

ALTER TABLE ONLY public.usuarios
    ADD CONSTRAINT usuarios_pkey PRIMARY KEY (telegram_user_id);


--
-- Name: ventas ventas_pkey; Type: CONSTRAINT; Schema: public; Owner: botpymes
--

ALTER TABLE ONLY public.ventas
    ADD CONSTRAINT ventas_pkey PRIMARY KEY (id);


--
-- Name: idx_ventas_user; Type: INDEX; Schema: public; Owner: botpymes
--

CREATE INDEX idx_ventas_user ON public.ventas USING btree (telegram_user_id);


--
-- Name: cargas cargas_telegram_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: botpymes
--

ALTER TABLE ONLY public.cargas
    ADD CONSTRAINT cargas_telegram_user_id_fkey FOREIGN KEY (telegram_user_id) REFERENCES public.usuarios(telegram_user_id);


--
-- Name: ventas ventas_carga_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: botpymes
--

ALTER TABLE ONLY public.ventas
    ADD CONSTRAINT ventas_carga_id_fkey FOREIGN KEY (carga_id) REFERENCES public.cargas(id);


--
-- Name: ventas ventas_telegram_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: botpymes
--

ALTER TABLE ONLY public.ventas
    ADD CONSTRAINT ventas_telegram_user_id_fkey FOREIGN KEY (telegram_user_id) REFERENCES public.usuarios(telegram_user_id);


--
-- PostgreSQL database dump complete
--

\unrestrict JZI3C2EGxuVGCnEuaYaLYpPR5g663HOH8fG6HNzQWCcr8ZN054luTzt8T5I9G1J

