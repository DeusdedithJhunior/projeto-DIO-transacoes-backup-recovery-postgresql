--
-- PostgreSQL database dump
--

\restrict yKKH5atkKNmZoXZ7qhJFjPA84JoqaTlVrriPBwZdEftbEcJaTc3qaD2hP0fo42J

-- Dumped from database version 18.6
-- Dumped by pg_dump version 18.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: ecommerce; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA ecommerce;


ALTER SCHEMA ecommerce OWNER TO postgres;

--
-- Name: fn_log_pedido(); Type: FUNCTION; Schema: ecommerce; Owner: postgres
--

CREATE FUNCTION ecommerce.fn_log_pedido() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO ecommerce.log_pedido (id_pedido, operacao, status_novo)
        VALUES (NEW.id_pedido, 'INSERT', NEW.status);
    ELSIF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO ecommerce.log_pedido (id_pedido, operacao, status_anterior, status_novo)
        VALUES (NEW.id_pedido, 'UPDATE STATUS', OLD.status, NEW.status);
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION ecommerce.fn_log_pedido() OWNER TO postgres;

--
-- Name: sp_finalizar_pedido(integer, jsonb, integer, integer, numeric, integer, text, text); Type: PROCEDURE; Schema: ecommerce; Owner: postgres
--

CREATE PROCEDURE ecommerce.sp_finalizar_pedido(IN p_id_cliente integer, IN p_itens jsonb, IN p_id_forma integer, IN p_id_local integer, IN p_frete numeric DEFAULT 0, INOUT p_id_pedido integer DEFAULT NULL::integer, INOUT p_resultado text DEFAULT NULL::text, INOUT p_mensagem text DEFAULT NULL::text)
    LANGUAGE plpgsql
    AS $_$
DECLARE
    v_item        RECORD;
    v_estoque     INT;
    v_valor       NUMERIC(10,2);
    v_total       NUMERIC(10,2) := 0;
    v_forma_ok    BOOLEAN;
BEGIN
    p_id_pedido := NULL;

    -- 1. ValidaÃ§Ãµes iniciais (nada foi gravado ainda)
    IF NOT EXISTS (SELECT 1 FROM ecommerce.cliente WHERE id_cliente = p_id_cliente) THEN
        p_resultado := 'ROLLBACK TOTAL';
        p_mensagem  := format('Cliente %s nÃ£o existe. Nada foi gravado.', p_id_cliente);
        ROLLBACK;
        RAISE NOTICE '%', p_mensagem;
        RETURN;
    END IF;

    IF p_itens IS NULL OR jsonb_typeof(p_itens) <> 'array' OR jsonb_array_length(p_itens) = 0 THEN
        p_resultado := 'ROLLBACK TOTAL';
        p_mensagem  := 'Lista de itens vazia ou invÃ¡lida. Nada foi gravado.';
        ROLLBACK;
        RAISE NOTICE '%', p_mensagem;
        RETURN;
    END IF;

    -- 2. Insere o pedido
    INSERT INTO ecommerce.pedido (id_cliente, status, descricao, frete)
    VALUES (p_id_cliente, 'Em processamento', 'Pedido via sp_finalizar_pedido', p_frete)
    RETURNING id_pedido INTO p_id_pedido;

    -- 3. Itens: valida estoque, insere item e baixa estoque
    FOR v_item IN
        SELECT (x ->> 'id_produto')::INT AS id_produto,
               (x ->> 'quantidade')::INT AS quantidade
        FROM jsonb_array_elements(p_itens) AS x
    LOOP
        SELECT valor INTO v_valor
        FROM ecommerce.produto
        WHERE id_produto = v_item.id_produto;

        -- FOR UPDATE trava a linha do estoque atÃ© o fim da transaÃ§Ã£o,
        -- evitando que outra sessÃ£o venda a mesma unidade ao mesmo tempo
        SELECT quantidade INTO v_estoque
        FROM ecommerce.estoque
        WHERE id_produto = v_item.id_produto
          AND id_local   = p_id_local
        FOR UPDATE;

        IF v_valor IS NULL OR v_estoque IS NULL OR v_item.quantidade IS NULL
           OR v_item.quantidade <= 0 OR v_estoque < v_item.quantidade THEN
            p_mensagem := CASE
                WHEN v_valor IS NULL THEN
                    format('Produto %s nÃ£o existe.', v_item.id_produto)
                WHEN v_item.quantidade IS NULL OR v_item.quantidade <= 0 THEN
                    format('Quantidade invÃ¡lida para o produto %s.', v_item.id_produto)
                ELSE
                    format('Estoque insuficiente do produto %s no local %s: pedido %s, disponÃ­vel %s.',
                           v_item.id_produto, p_id_local, v_item.quantidade, COALESCE(v_estoque, 0))
                END
                || format(' Pedido %s desfeito, nada foi gravado.', p_id_pedido);

            ROLLBACK;                       -- ROLLBACK TOTAL: desfaz pedido, itens e baixas
            p_id_pedido := NULL;
            p_resultado := 'ROLLBACK TOTAL';
            RAISE NOTICE '%', p_mensagem;
            RETURN;
        END IF;

        INSERT INTO ecommerce.item_pedido (id_pedido, id_produto, quantidade, valor_unitario)
        VALUES (p_id_pedido, v_item.id_produto, v_item.quantidade, v_valor);

        UPDATE ecommerce.estoque
           SET quantidade = quantidade - v_item.quantidade
         WHERE id_produto = v_item.id_produto
           AND id_local   = p_id_local;

        v_total := v_total + v_valor * v_item.quantidade;
    END LOOP;

    v_total := v_total + COALESCE(p_frete, 0);

    -- 4. Pagamento (etapa secundÃ¡ria) â€“ bloco aninhado = savepoint implÃ­cito
    BEGIN
        SELECT TRUE INTO v_forma_ok
        FROM ecommerce.forma_pagamento
        WHERE id_forma = p_id_forma
          AND id_cliente = p_id_cliente
          AND ativo;

        INSERT INTO ecommerce.pagamento (id_pedido, id_forma, valor, status, data_pagamento)
        VALUES (p_id_pedido, p_id_forma, v_total, 'Aprovado', clock_timestamp());

        -- A trigger registra esta mudanÃ§a de status no log
        UPDATE ecommerce.pedido SET status = 'Confirmado' WHERE id_pedido = p_id_pedido;

        -- ValidaÃ§Ã£o feita depois dos comandos de propÃ³sito: ao falhar,
        -- mostra que o INSERT do pagamento, o UPDATE e o log gerado
        -- pela trigger sÃ£o todos desfeitos juntos.
        IF v_forma_ok IS NULL THEN
            RAISE EXCEPTION 'Forma de pagamento % invÃ¡lida, inativa ou de outro cliente', p_id_forma;
        END IF;

        p_resultado := 'SUCESSO';
        p_mensagem  := format('Pedido %s confirmado. Total R$ %s pago com a forma %s.',
                              p_id_pedido, v_total, p_id_forma);
    EXCEPTION
        WHEN OTHERS THEN
            -- ROLLBACK PARCIAL: sÃ³ o que foi feito dentro deste bloco foi
            -- desfeito. Pedido, itens e baixa de estoque continuam valendo.
            INSERT INTO ecommerce.log_pedido (id_pedido, operacao, detalhe)
            VALUES (p_id_pedido, 'PAGAMENTO FALHOU', left(SQLERRM, 255));

            p_resultado := 'ROLLBACK PARCIAL';
            p_mensagem  := format('Pedido %s gravado como "Em processamento", mas o pagamento nÃ£o foi registrado: %s',
                                  p_id_pedido, SQLERRM);
    END;

    -- 5. Confirma tudo o que restou (fora de bloco com EXCEPTION)
    COMMIT;
    RAISE NOTICE '%', p_mensagem;
END;
$_$;


ALTER PROCEDURE ecommerce.sp_finalizar_pedido(IN p_id_cliente integer, IN p_itens jsonb, IN p_id_forma integer, IN p_id_local integer, IN p_frete numeric, INOUT p_id_pedido integer, INOUT p_resultado text, INOUT p_mensagem text) OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: categoria; Type: TABLE; Schema: ecommerce; Owner: postgres
--

CREATE TABLE ecommerce.categoria (
    id_categoria integer NOT NULL,
    nome character varying(50) NOT NULL
);


ALTER TABLE ecommerce.categoria OWNER TO postgres;

--
-- Name: categoria_id_categoria_seq; Type: SEQUENCE; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ecommerce.categoria ALTER COLUMN id_categoria ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME ecommerce.categoria_id_categoria_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: cliente; Type: TABLE; Schema: ecommerce; Owner: postgres
--

CREATE TABLE ecommerce.cliente (
    id_cliente integer NOT NULL,
    tipo character(2) NOT NULL,
    nome character varying(100) NOT NULL,
    cpf character(11),
    cnpj character(14),
    email character varying(100) NOT NULL,
    telefone character varying(15),
    endereco character varying(150),
    cidade character varying(50),
    uf character(2),
    data_cadastro date DEFAULT CURRENT_DATE NOT NULL,
    CONSTRAINT chk_cliente_cnpj CHECK ((cnpj ~ '^[0-9]{14}$'::text)),
    CONSTRAINT chk_cliente_cpf CHECK ((cpf ~ '^[0-9]{11}$'::text)),
    CONSTRAINT chk_cliente_pf_pj CHECK ((((tipo = 'PF'::bpchar) AND (cpf IS NOT NULL) AND (cnpj IS NULL)) OR ((tipo = 'PJ'::bpchar) AND (cnpj IS NOT NULL) AND (cpf IS NULL)))),
    CONSTRAINT cliente_tipo_check CHECK ((tipo = ANY (ARRAY['PF'::bpchar, 'PJ'::bpchar])))
);


ALTER TABLE ecommerce.cliente OWNER TO postgres;

--
-- Name: cliente_id_cliente_seq; Type: SEQUENCE; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ecommerce.cliente ALTER COLUMN id_cliente ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME ecommerce.cliente_id_cliente_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: entrega; Type: TABLE; Schema: ecommerce; Owner: postgres
--

CREATE TABLE ecommerce.entrega (
    id_entrega integer NOT NULL,
    id_pedido integer NOT NULL,
    status character varying(20) DEFAULT 'Aguardando envio'::character varying NOT NULL,
    codigo_rastreio character varying(20),
    transportadora character varying(50),
    data_envio date,
    data_entrega date,
    CONSTRAINT chk_entrega_datas CHECK (((data_entrega IS NULL) OR (data_entrega >= data_envio))),
    CONSTRAINT chk_entrega_rastreio CHECK ((((status)::text = 'Aguardando envio'::text) OR ((status)::text = 'Cancelada'::text) OR (codigo_rastreio IS NOT NULL))),
    CONSTRAINT entrega_status_check CHECK (((status)::text = ANY ((ARRAY['Aguardando envio'::character varying, 'Em transporte'::character varying, 'Entregue'::character varying, 'Devolvido'::character varying, 'Cancelada'::character varying])::text[])))
);


ALTER TABLE ecommerce.entrega OWNER TO postgres;

--
-- Name: entrega_id_entrega_seq; Type: SEQUENCE; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ecommerce.entrega ALTER COLUMN id_entrega ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME ecommerce.entrega_id_entrega_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: estoque; Type: TABLE; Schema: ecommerce; Owner: postgres
--

CREATE TABLE ecommerce.estoque (
    id_produto integer NOT NULL,
    id_local integer NOT NULL,
    quantidade integer DEFAULT 0 NOT NULL,
    CONSTRAINT estoque_quantidade_check CHECK ((quantidade >= 0))
);


ALTER TABLE ecommerce.estoque OWNER TO postgres;

--
-- Name: forma_pagamento; Type: TABLE; Schema: ecommerce; Owner: postgres
--

CREATE TABLE ecommerce.forma_pagamento (
    id_forma integer NOT NULL,
    id_cliente integer NOT NULL,
    tipo character varying(20) NOT NULL,
    bandeira character varying(20),
    final_cartao character(4),
    ativo boolean DEFAULT true NOT NULL,
    CONSTRAINT chk_forma_cartao CHECK (((((tipo)::text ~~ 'CartÃ£o%'::text) AND (final_cartao ~ '^[0-9]{4}$'::text)) OR (((tipo)::text !~~ 'CartÃ£o%'::text) AND (final_cartao IS NULL)))),
    CONSTRAINT forma_pagamento_tipo_check CHECK (((tipo)::text = ANY ((ARRAY['CartÃ£o de crÃ©dito'::character varying, 'CartÃ£o de dÃ©bito'::character varying, 'Pix'::character varying, 'Boleto'::character varying])::text[])))
);


ALTER TABLE ecommerce.forma_pagamento OWNER TO postgres;

--
-- Name: forma_pagamento_id_forma_seq; Type: SEQUENCE; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ecommerce.forma_pagamento ALTER COLUMN id_forma ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME ecommerce.forma_pagamento_id_forma_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: fornecedor; Type: TABLE; Schema: ecommerce; Owner: postgres
--

CREATE TABLE ecommerce.fornecedor (
    id_fornecedor integer NOT NULL,
    razao_social character varying(100) NOT NULL,
    cnpj character(14) NOT NULL,
    contato character varying(15),
    CONSTRAINT fornecedor_cnpj_check CHECK ((cnpj ~ '^[0-9]{14}$'::text))
);


ALTER TABLE ecommerce.fornecedor OWNER TO postgres;

--
-- Name: fornecedor_id_fornecedor_seq; Type: SEQUENCE; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ecommerce.fornecedor ALTER COLUMN id_fornecedor ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME ecommerce.fornecedor_id_fornecedor_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: item_pedido; Type: TABLE; Schema: ecommerce; Owner: postgres
--

CREATE TABLE ecommerce.item_pedido (
    id_pedido integer NOT NULL,
    id_produto integer NOT NULL,
    quantidade integer NOT NULL,
    valor_unitario numeric(10,2) NOT NULL,
    CONSTRAINT item_pedido_quantidade_check CHECK ((quantidade > 0)),
    CONSTRAINT item_pedido_valor_unitario_check CHECK ((valor_unitario > (0)::numeric))
);


ALTER TABLE ecommerce.item_pedido OWNER TO postgres;

--
-- Name: local_estoque; Type: TABLE; Schema: ecommerce; Owner: postgres
--

CREATE TABLE ecommerce.local_estoque (
    id_local integer NOT NULL,
    nome character varying(50) NOT NULL,
    cidade character varying(50) NOT NULL,
    uf character(2) NOT NULL
);


ALTER TABLE ecommerce.local_estoque OWNER TO postgres;

--
-- Name: local_estoque_id_local_seq; Type: SEQUENCE; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ecommerce.local_estoque ALTER COLUMN id_local ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME ecommerce.local_estoque_id_local_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: log_pedido; Type: TABLE; Schema: ecommerce; Owner: postgres
--

CREATE TABLE ecommerce.log_pedido (
    id_log integer NOT NULL,
    id_pedido integer NOT NULL,
    operacao character varying(30) NOT NULL,
    status_anterior character varying(20),
    status_novo character varying(20),
    detalhe character varying(255),
    data_log timestamp without time zone DEFAULT clock_timestamp() NOT NULL,
    usuario character varying(63) DEFAULT CURRENT_USER NOT NULL
);


ALTER TABLE ecommerce.log_pedido OWNER TO postgres;

--
-- Name: log_pedido_id_log_seq; Type: SEQUENCE; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ecommerce.log_pedido ALTER COLUMN id_log ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME ecommerce.log_pedido_id_log_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: pagamento; Type: TABLE; Schema: ecommerce; Owner: postgres
--

CREATE TABLE ecommerce.pagamento (
    id_pagamento integer NOT NULL,
    id_pedido integer NOT NULL,
    id_forma integer NOT NULL,
    valor numeric(10,2) NOT NULL,
    status character varying(15) DEFAULT 'Pendente'::character varying NOT NULL,
    data_pagamento timestamp without time zone,
    CONSTRAINT pagamento_status_check CHECK (((status)::text = ANY ((ARRAY['Pendente'::character varying, 'Aprovado'::character varying, 'Recusado'::character varying, 'Estornado'::character varying])::text[]))),
    CONSTRAINT pagamento_valor_check CHECK ((valor > (0)::numeric))
);


ALTER TABLE ecommerce.pagamento OWNER TO postgres;

--
-- Name: pagamento_id_pagamento_seq; Type: SEQUENCE; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ecommerce.pagamento ALTER COLUMN id_pagamento ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME ecommerce.pagamento_id_pagamento_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: pedido; Type: TABLE; Schema: ecommerce; Owner: postgres
--

CREATE TABLE ecommerce.pedido (
    id_pedido integer NOT NULL,
    id_cliente integer NOT NULL,
    data_pedido timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    status character varying(20) DEFAULT 'Em processamento'::character varying NOT NULL,
    descricao character varying(255),
    frete numeric(10,2) DEFAULT 0 NOT NULL,
    CONSTRAINT pedido_frete_check CHECK ((frete >= (0)::numeric)),
    CONSTRAINT pedido_status_check CHECK (((status)::text = ANY ((ARRAY['Em processamento'::character varying, 'Confirmado'::character varying, 'Cancelado'::character varying, 'ConcluÃ­do'::character varying])::text[])))
);


ALTER TABLE ecommerce.pedido OWNER TO postgres;

--
-- Name: pedido_id_pedido_seq; Type: SEQUENCE; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ecommerce.pedido ALTER COLUMN id_pedido ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME ecommerce.pedido_id_pedido_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: produto; Type: TABLE; Schema: ecommerce; Owner: postgres
--

CREATE TABLE ecommerce.produto (
    id_produto integer NOT NULL,
    nome character varying(100) NOT NULL,
    id_categoria integer NOT NULL,
    descricao character varying(255),
    valor numeric(10,2) NOT NULL,
    avaliacao numeric(2,1),
    para_criancas boolean DEFAULT false NOT NULL,
    CONSTRAINT produto_avaliacao_check CHECK (((avaliacao >= (0)::numeric) AND (avaliacao <= (5)::numeric))),
    CONSTRAINT produto_valor_check CHECK ((valor > (0)::numeric))
);


ALTER TABLE ecommerce.produto OWNER TO postgres;

--
-- Name: produto_fornecedor; Type: TABLE; Schema: ecommerce; Owner: postgres
--

CREATE TABLE ecommerce.produto_fornecedor (
    id_fornecedor integer NOT NULL,
    id_produto integer NOT NULL,
    quantidade integer DEFAULT 0 NOT NULL,
    CONSTRAINT produto_fornecedor_quantidade_check CHECK ((quantidade >= 0))
);


ALTER TABLE ecommerce.produto_fornecedor OWNER TO postgres;

--
-- Name: produto_id_produto_seq; Type: SEQUENCE; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ecommerce.produto ALTER COLUMN id_produto ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME ecommerce.produto_id_produto_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: produto_vendedor; Type: TABLE; Schema: ecommerce; Owner: postgres
--

CREATE TABLE ecommerce.produto_vendedor (
    id_vendedor integer NOT NULL,
    id_produto integer NOT NULL,
    quantidade integer DEFAULT 0 NOT NULL,
    CONSTRAINT produto_vendedor_quantidade_check CHECK ((quantidade >= 0))
);


ALTER TABLE ecommerce.produto_vendedor OWNER TO postgres;

--
-- Name: vendedor_terceiro; Type: TABLE; Schema: ecommerce; Owner: postgres
--

CREATE TABLE ecommerce.vendedor_terceiro (
    id_vendedor integer NOT NULL,
    razao_social character varying(100) NOT NULL,
    nome_fantasia character varying(100),
    cnpj character(14),
    cpf character(11),
    cidade character varying(50),
    uf character(2),
    CONSTRAINT chk_vendedor_pf_pj CHECK ((((cnpj IS NOT NULL) AND (cpf IS NULL)) OR ((cpf IS NOT NULL) AND (cnpj IS NULL))))
);


ALTER TABLE ecommerce.vendedor_terceiro OWNER TO postgres;

--
-- Name: vendedor_terceiro_id_vendedor_seq; Type: SEQUENCE; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ecommerce.vendedor_terceiro ALTER COLUMN id_vendedor ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME ecommerce.vendedor_terceiro_id_vendedor_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Data for Name: categoria; Type: TABLE DATA; Schema: ecommerce; Owner: postgres
--

COPY ecommerce.categoria (id_categoria, nome) FROM stdin;
1	EletrÃ´nicos
2	InformÃ¡tica
3	Casa e Cozinha
4	Papelaria
5	Brinquedos
6	Esporte
\.


--
-- Data for Name: cliente; Type: TABLE DATA; Schema: ecommerce; Owner: postgres
--

COPY ecommerce.cliente (id_cliente, tipo, nome, cpf, cnpj, email, telefone, endereco, cidade, uf, data_cadastro) FROM stdin;
1	PF	Ana Beatriz Sousa	11122233344	\N	ana.sousa@email.com	98991110001	Rua das Hortas, 120	SÃ£o LuÃ­s	MA	2025-01-15
2	PF	Bruno Carvalho Mendes	22233344455	\N	bruno.mendes@email.com	98991110002	Av. dos Holandeses, 45	SÃ£o LuÃ­s	MA	2025-02-03
3	PF	Camila Ferreira Lopes	33344455566	\N	camila.lopes@email.com	86991110003	Rua Areolino de Abreu, 300	Teresina	PI	2025-02-20
4	PF	Diego Martins AraÃºjo	44455566677	\N	diego.araujo@email.com	85991110004	Av. Beira Mar, 1500	Fortaleza	CE	2025-03-11
5	PF	Eduarda Nunes Pereira	55566677788	\N	eduarda.nunes@email.com	98991110005	Rua Grande, 800	SÃ£o LuÃ­s	MA	2025-04-02
6	PF	Felipe Ribeiro Gomes	66677788899	\N	felipe.gomes@email.com	91991110006	Tv. Padre EutÃ­quio, 77	BelÃ©m	PA	2025-05-19
7	PF	Gabriela Teixeira Melo	77788899900	\N	gabriela.melo@email.com	99991110007	Rua SimplÃ­cio Moreira, 210	Imperatriz	MA	2025-06-08
8	PJ	Papelaria Ilha Ltda	\N	12345678000190	compras@papelariailha.com.br	9832110008	Rua do Sol, 55	SÃ£o LuÃ­s	MA	2025-03-01
9	PJ	Tech Norte SoluÃ§Ãµes ME	\N	23456789000101	financeiro@technorte.com.br	8632110009	Av. Frei Serafim, 900	Teresina	PI	2025-04-22
10	PJ	Mercadinho Bom PreÃ§o Eireli	\N	34567890000112	contato@bompreco.com.br	9832110010	Av. JerÃ´nimo de Albuquerque, 12	SÃ£o LuÃ­s	MA	2025-07-10
\.


--
-- Data for Name: entrega; Type: TABLE DATA; Schema: ecommerce; Owner: postgres
--

COPY ecommerce.entrega (id_entrega, id_pedido, status, codigo_rastreio, transportadora, data_envio, data_entrega) FROM stdin;
1	1	Entregue	BR100000001MA	Correios	2026-01-06	2026-01-09
2	2	Entregue	BR100000002MA	Jadlog	2026-01-19	2026-01-25
3	3	Entregue	BR100000003MA	Correios	2026-02-03	2026-02-05
4	4	Entregue	BR100000004PI	Correios	2026-02-15	2026-02-21
5	5	Entregue	BR100000005MA	Transportadora Ilha	2026-03-04	2026-03-05
6	6	Cancelada	\N	\N	\N	\N
7	7	Entregue	BR100000007PI	Jadlog	2026-04-11	2026-04-16
8	8	Devolvido	BR100000008MA	Correios	2026-05-06	2026-05-10
9	9	Entregue	BR100000009PA	Correios	2026-06-16	2026-06-24
10	10	Entregue	BR100000010MA	Correios	2026-07-08	2026-07-10
11	11	Em transporte	BR100000011MA	Transportadora Ilha	2026-11-12	\N
12	12	Em transporte	BR100000012MA	Correios	2026-11-14	\N
13	13	Em transporte	BR100000013MA	Jadlog	2026-11-03	\N
14	14	Aguardando envio	\N	\N	\N	\N
15	15	Aguardando envio	\N	\N	\N	\N
\.


--
-- Data for Name: estoque; Type: TABLE DATA; Schema: ecommerce; Owner: postgres
--

COPY ecommerce.estoque (id_produto, id_local, quantidade) FROM stdin;
1	3	80
2	1	40
3	2	60
4	1	15
4	2	10
5	2	150
6	1	70
7	3	30
8	3	25
9	2	30
10	1	50
13	1	20
14	1	18
15	3	40
16	3	55
11	1	597
8	1	44
1	1	119
5	1	197
12	1	248
\.


--
-- Data for Name: forma_pagamento; Type: TABLE DATA; Schema: ecommerce; Owner: postgres
--

COPY ecommerce.forma_pagamento (id_forma, id_cliente, tipo, bandeira, final_cartao, ativo) FROM stdin;
1	1	CartÃ£o de crÃ©dito	Visa	4821	t
2	1	Pix	\N	\N	t
3	2	CartÃ£o de crÃ©dito	Mastercard	7710	t
4	3	Pix	\N	\N	t
5	4	CartÃ£o de dÃ©bito	Elo	3302	t
6	5	Boleto	\N	\N	t
7	6	CartÃ£o de crÃ©dito	Visa	9045	t
8	7	Pix	\N	\N	t
9	8	Boleto	\N	\N	t
10	8	Pix	\N	\N	t
11	9	CartÃ£o de crÃ©dito	Mastercard	1188	t
12	10	Boleto	\N	\N	t
13	2	Pix	\N	\N	t
\.


--
-- Data for Name: fornecedor; Type: TABLE DATA; Schema: ecommerce; Owner: postgres
--

COPY ecommerce.fornecedor (id_fornecedor, razao_social, cnpj, contato) FROM stdin;
1	Eletro Distribuidora Nordeste SA	45678901000123	8133330001
2	InfoParts ComÃ©rcio Ltda	56789012000134	1133330002
3	Casa Forte Utilidades Ltda	67890123000145	9833330003
4	Papel & Cia Atacado Ltda	78901234000156	9833330004
\.


--
-- Data for Name: item_pedido; Type: TABLE DATA; Schema: ecommerce; Owner: postgres
--

COPY ecommerce.item_pedido (id_pedido, id_produto, quantidade, valor_unitario) FROM stdin;
1	1	1	249.90
1	5	1	79.90
2	4	1	3899.00
2	7	1	899.00
3	11	3	32.90
3	12	1	54.90
4	2	1	599.00
5	11	50	29.90
5	12	20	49.90
6	8	1	429.90
7	6	5	269.00
7	5	5	75.00
7	7	3	879.00
8	8	1	429.90
8	10	1	159.90
9	15	2	149.90
9	16	1	89.90
10	3	1	189.90
10	1	1	239.90
11	10	2	159.90
11	9	1	349.00
12	13	2	199.90
12	14	1	129.90
13	6	1	279.00
14	11	80	29.90
14	12	30	49.90
15	1	1	249.90
15	3	1	189.90
16	5	2	79.90
16	11	3	32.90
18	8	1	429.90
19	1	1	249.90
19	5	1	79.90
21	12	2	54.90
\.


--
-- Data for Name: local_estoque; Type: TABLE DATA; Schema: ecommerce; Owner: postgres
--

COPY ecommerce.local_estoque (id_local, nome, cidade, uf) FROM stdin;
1	CD SÃ£o LuÃ­s	SÃ£o LuÃ­s	MA
2	CD Teresina	Teresina	PI
3	CD Fortaleza	Fortaleza	CE
\.


--
-- Data for Name: log_pedido; Type: TABLE DATA; Schema: ecommerce; Owner: postgres
--

COPY ecommerce.log_pedido (id_log, id_pedido, operacao, status_anterior, status_novo, detalhe, data_log, usuario) FROM stdin;
1	19	INSERT	\N	Em processamento	\N	2026-11-22 09:21:26.87117	postgres
2	19	UPDATE STATUS	Em processamento	Confirmado	\N	2026-11-22 09:21:26.895014	postgres
4	21	INSERT	\N	Em processamento	\N	2026-11-22 09:21:27.520117	postgres
6	21	PAGAMENTO FALHOU	\N	\N	Forma de pagamento 1 invÃ¡lida, inativa ou de outro cliente	2026-11-22 09:21:27.523114	postgres
\.


--
-- Data for Name: pagamento; Type: TABLE DATA; Schema: ecommerce; Owner: postgres
--

COPY ecommerce.pagamento (id_pagamento, id_pedido, id_forma, valor, status, data_pagamento) FROM stdin;
1	1	1	344.80	Aprovado	2026-01-05 10:13:00
2	2	3	3000.00	Aprovado	2026-01-18 14:41:00
3	2	13	1823.00	Aprovado	2026-01-18 14:43:00
4	3	2	153.60	Aprovado	2026-02-02 09:06:00
5	4	4	617.50	Aprovado	2026-02-14 20:31:00
6	5	9	2493.00	Aprovado	2026-03-03 10:00:00
7	6	5	459.90	Estornado	2026-03-22 16:46:00
8	7	11	4357.00	Aprovado	2026-04-10 11:21:00
9	8	6	601.80	Aprovado	2026-05-05 08:30:00
10	9	7	424.70	Aprovado	2026-06-15 13:01:00
11	10	13	429.80	Aprovado	2026-07-07 10:31:00
12	11	12	668.80	Aprovado	2026-08-20 09:00:00
13	12	8	551.70	Aprovado	2026-09-25 21:16:00
14	13	1	279.00	Aprovado	2026-10-30 15:36:00
15	14	10	3889.00	Pendente	\N
16	15	4	454.70	Pendente	\N
17	19	1	344.80	Aprovado	2026-11-22 09:21:26.893899
\.


--
-- Data for Name: pedido; Type: TABLE DATA; Schema: ecommerce; Owner: postgres
--

COPY ecommerce.pedido (id_pedido, id_cliente, data_pedido, status, descricao, frete) FROM stdin;
1	1	2026-01-05 10:12:00	ConcluÃ­do	Compra via app	15.00
2	2	2026-01-18 14:40:00	ConcluÃ­do	Compra via site	25.00
3	1	2026-02-02 09:05:00	ConcluÃ­do	Compra via app	0.00
4	3	2026-02-14 20:30:00	ConcluÃ­do	Presente	18.50
5	8	2026-03-01 08:00:00	ConcluÃ­do	ReposiÃ§Ã£o de estoque	0.00
6	4	2026-03-22 16:45:00	Cancelado	DesistÃªncia	30.00
7	9	2026-04-10 11:20:00	ConcluÃ­do	Equipamentos escritÃ³rio	0.00
8	5	2026-05-03 19:10:00	ConcluÃ­do	Compra via site	12.00
9	6	2026-06-15 13:00:00	ConcluÃ­do	Compra via app	35.00
10	2	2026-07-07 10:30:00	ConcluÃ­do	Compra via app	0.00
11	10	2026-08-19 07:50:00	Confirmado	Compra mensal	0.00
12	7	2026-09-25 21:15:00	Confirmado	Dia das crianÃ§as	22.00
13	1	2026-10-30 15:35:00	Confirmado	Compra via site	0.00
14	8	2026-11-10 09:40:00	Em processamento	Volta Ã s aulas	0.00
15	3	2026-11-18 18:25:00	Em processamento	Compra via app	14.90
16	5	2026-11-22 09:21:24.124892	Confirmado	TransaÃ§Ã£o 1 - COMMIT	12.00
18	3	2026-11-22 09:21:24.830503	Confirmado	TransaÃ§Ã£o 3 - SAVEPOINT	18.50
19	1	2026-11-22 09:21:26.865046	Confirmado	Pedido via sp_finalizar_pedido	15.00
21	3	2026-11-22 09:21:27.519336	Em processamento	Pedido via sp_finalizar_pedido	0.00
\.


--
-- Data for Name: produto; Type: TABLE DATA; Schema: ecommerce; Owner: postgres
--

COPY ecommerce.produto (id_produto, nome, id_categoria, descricao, valor, avaliacao, para_criancas) FROM stdin;
1	Fone Bluetooth X200	1	Fone sem fio com cancelamento de ruÃ­do	249.90	4.5	f
2	Smartwatch Fit Pro	1	RelÃ³gio inteligente com GPS	599.00	4.2	f
3	Caixa de Som PortÃ¡til 20W	1	Resistente Ã  Ã¡gua	189.90	4.4	f
4	Notebook 15" i5 16GB	2	SSD 512GB	3899.00	4.6	f
5	Mouse Sem Fio ErgonÃ´mico	2	2.4GHz, 1600 DPI	79.90	4.3	f
6	Teclado MecÃ¢nico ABNT2	2	Switch azul, retroiluminado	279.00	4.7	f
7	Monitor 24" Full HD	2	IPS 75Hz	899.00	4.5	f
8	Air Fryer 4L	3	1500W, 127V	429.90	4.6	f
9	Jogo de Panelas Antiaderente	3	5 peÃ§as	349.00	4.1	f
10	Cafeteira ElÃ©trica 30 xÃ­caras	3	Com jarra de vidro	159.90	4.0	f
11	Caderno UniversitÃ¡rio 10 mat.	4	200 folhas	32.90	4.8	f
12	Caneta EsferogrÃ¡fica cx 50	4	Azul	54.90	4.5	f
13	Kit Blocos de Montar 500 pÃ§	5	Idade 6+	199.90	4.9	t
14	Boneca Articulada	5	Com acessÃ³rios	129.90	4.3	t
15	Bola de Futebol Oficial	6	Tamanho 5	149.90	4.6	f
16	Tapete de Yoga 6mm	6	Antiderrapante	89.90	4.4	f
\.


--
-- Data for Name: produto_fornecedor; Type: TABLE DATA; Schema: ecommerce; Owner: postgres
--

COPY ecommerce.produto_fornecedor (id_fornecedor, id_produto, quantidade) FROM stdin;
1	1	300
1	2	120
1	3	200
2	4	50
2	5	500
2	6	150
2	7	80
3	8	100
3	9	60
3	10	90
4	11	1000
4	12	400
\.


--
-- Data for Name: produto_vendedor; Type: TABLE DATA; Schema: ecommerce; Owner: postgres
--

COPY ecommerce.produto_vendedor (id_vendedor, id_produto, quantidade) FROM stdin;
1	13	40
1	14	35
2	15	60
2	16	80
3	1	15
3	3	10
\.


--
-- Data for Name: vendedor_terceiro; Type: TABLE DATA; Schema: ecommerce; Owner: postgres
--

COPY ecommerce.vendedor_terceiro (id_vendedor, razao_social, nome_fantasia, cnpj, cpf, cidade, uf) FROM stdin;
1	Brinquedos da Ilha Ltda	Ilha Kids	89012345000167	\N	SÃ£o LuÃ­s	MA
2	Esporte Total ME	Esporte Total	90123456000178	\N	Fortaleza	CE
3	Marcos VinÃ­cius Rocha	MV Gadgets	\N	88899900011	Teresina	PI
\.


--
-- Name: categoria_id_categoria_seq; Type: SEQUENCE SET; Schema: ecommerce; Owner: postgres
--

SELECT pg_catalog.setval('ecommerce.categoria_id_categoria_seq', 6, true);


--
-- Name: cliente_id_cliente_seq; Type: SEQUENCE SET; Schema: ecommerce; Owner: postgres
--

SELECT pg_catalog.setval('ecommerce.cliente_id_cliente_seq', 10, true);


--
-- Name: entrega_id_entrega_seq; Type: SEQUENCE SET; Schema: ecommerce; Owner: postgres
--

SELECT pg_catalog.setval('ecommerce.entrega_id_entrega_seq', 15, true);


--
-- Name: forma_pagamento_id_forma_seq; Type: SEQUENCE SET; Schema: ecommerce; Owner: postgres
--

SELECT pg_catalog.setval('ecommerce.forma_pagamento_id_forma_seq', 13, true);


--
-- Name: fornecedor_id_fornecedor_seq; Type: SEQUENCE SET; Schema: ecommerce; Owner: postgres
--

SELECT pg_catalog.setval('ecommerce.fornecedor_id_fornecedor_seq', 4, true);


--
-- Name: local_estoque_id_local_seq; Type: SEQUENCE SET; Schema: ecommerce; Owner: postgres
--

SELECT pg_catalog.setval('ecommerce.local_estoque_id_local_seq', 3, true);


--
-- Name: log_pedido_id_log_seq; Type: SEQUENCE SET; Schema: ecommerce; Owner: postgres
--

SELECT pg_catalog.setval('ecommerce.log_pedido_id_log_seq', 6, true);


--
-- Name: pagamento_id_pagamento_seq; Type: SEQUENCE SET; Schema: ecommerce; Owner: postgres
--

SELECT pg_catalog.setval('ecommerce.pagamento_id_pagamento_seq', 18, true);


--
-- Name: pedido_id_pedido_seq; Type: SEQUENCE SET; Schema: ecommerce; Owner: postgres
--

SELECT pg_catalog.setval('ecommerce.pedido_id_pedido_seq', 21, true);


--
-- Name: produto_id_produto_seq; Type: SEQUENCE SET; Schema: ecommerce; Owner: postgres
--

SELECT pg_catalog.setval('ecommerce.produto_id_produto_seq', 16, true);


--
-- Name: vendedor_terceiro_id_vendedor_seq; Type: SEQUENCE SET; Schema: ecommerce; Owner: postgres
--

SELECT pg_catalog.setval('ecommerce.vendedor_terceiro_id_vendedor_seq', 3, true);


--
-- Name: categoria categoria_nome_key; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.categoria
    ADD CONSTRAINT categoria_nome_key UNIQUE (nome);


--
-- Name: categoria categoria_pkey; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.categoria
    ADD CONSTRAINT categoria_pkey PRIMARY KEY (id_categoria);


--
-- Name: cliente cliente_cnpj_key; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.cliente
    ADD CONSTRAINT cliente_cnpj_key UNIQUE (cnpj);


--
-- Name: cliente cliente_cpf_key; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.cliente
    ADD CONSTRAINT cliente_cpf_key UNIQUE (cpf);


--
-- Name: cliente cliente_email_key; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.cliente
    ADD CONSTRAINT cliente_email_key UNIQUE (email);


--
-- Name: cliente cliente_pkey; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.cliente
    ADD CONSTRAINT cliente_pkey PRIMARY KEY (id_cliente);


--
-- Name: entrega entrega_codigo_rastreio_key; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.entrega
    ADD CONSTRAINT entrega_codigo_rastreio_key UNIQUE (codigo_rastreio);


--
-- Name: entrega entrega_id_pedido_key; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.entrega
    ADD CONSTRAINT entrega_id_pedido_key UNIQUE (id_pedido);


--
-- Name: entrega entrega_pkey; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.entrega
    ADD CONSTRAINT entrega_pkey PRIMARY KEY (id_entrega);


--
-- Name: estoque estoque_pkey; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.estoque
    ADD CONSTRAINT estoque_pkey PRIMARY KEY (id_produto, id_local);


--
-- Name: forma_pagamento forma_pagamento_pkey; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.forma_pagamento
    ADD CONSTRAINT forma_pagamento_pkey PRIMARY KEY (id_forma);


--
-- Name: fornecedor fornecedor_cnpj_key; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.fornecedor
    ADD CONSTRAINT fornecedor_cnpj_key UNIQUE (cnpj);


--
-- Name: fornecedor fornecedor_pkey; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.fornecedor
    ADD CONSTRAINT fornecedor_pkey PRIMARY KEY (id_fornecedor);


--
-- Name: item_pedido item_pedido_pkey; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.item_pedido
    ADD CONSTRAINT item_pedido_pkey PRIMARY KEY (id_pedido, id_produto);


--
-- Name: local_estoque local_estoque_nome_key; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.local_estoque
    ADD CONSTRAINT local_estoque_nome_key UNIQUE (nome);


--
-- Name: local_estoque local_estoque_pkey; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.local_estoque
    ADD CONSTRAINT local_estoque_pkey PRIMARY KEY (id_local);


--
-- Name: log_pedido log_pedido_pkey; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.log_pedido
    ADD CONSTRAINT log_pedido_pkey PRIMARY KEY (id_log);


--
-- Name: pagamento pagamento_pkey; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.pagamento
    ADD CONSTRAINT pagamento_pkey PRIMARY KEY (id_pagamento);


--
-- Name: pedido pedido_pkey; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.pedido
    ADD CONSTRAINT pedido_pkey PRIMARY KEY (id_pedido);


--
-- Name: produto_fornecedor produto_fornecedor_pkey; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.produto_fornecedor
    ADD CONSTRAINT produto_fornecedor_pkey PRIMARY KEY (id_fornecedor, id_produto);


--
-- Name: produto produto_pkey; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.produto
    ADD CONSTRAINT produto_pkey PRIMARY KEY (id_produto);


--
-- Name: produto_vendedor produto_vendedor_pkey; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.produto_vendedor
    ADD CONSTRAINT produto_vendedor_pkey PRIMARY KEY (id_vendedor, id_produto);


--
-- Name: vendedor_terceiro vendedor_terceiro_cnpj_key; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.vendedor_terceiro
    ADD CONSTRAINT vendedor_terceiro_cnpj_key UNIQUE (cnpj);


--
-- Name: vendedor_terceiro vendedor_terceiro_cpf_key; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.vendedor_terceiro
    ADD CONSTRAINT vendedor_terceiro_cpf_key UNIQUE (cpf);


--
-- Name: vendedor_terceiro vendedor_terceiro_pkey; Type: CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.vendedor_terceiro
    ADD CONSTRAINT vendedor_terceiro_pkey PRIMARY KEY (id_vendedor);


--
-- Name: pedido trg_log_pedido; Type: TRIGGER; Schema: ecommerce; Owner: postgres
--

CREATE TRIGGER trg_log_pedido AFTER INSERT OR UPDATE OF status ON ecommerce.pedido FOR EACH ROW EXECUTE FUNCTION ecommerce.fn_log_pedido();


--
-- Name: entrega entrega_id_pedido_fkey; Type: FK CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.entrega
    ADD CONSTRAINT entrega_id_pedido_fkey FOREIGN KEY (id_pedido) REFERENCES ecommerce.pedido(id_pedido) ON DELETE CASCADE;


--
-- Name: estoque estoque_id_local_fkey; Type: FK CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.estoque
    ADD CONSTRAINT estoque_id_local_fkey FOREIGN KEY (id_local) REFERENCES ecommerce.local_estoque(id_local);


--
-- Name: estoque estoque_id_produto_fkey; Type: FK CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.estoque
    ADD CONSTRAINT estoque_id_produto_fkey FOREIGN KEY (id_produto) REFERENCES ecommerce.produto(id_produto) ON DELETE CASCADE;


--
-- Name: pedido fk_pedido_cliente; Type: FK CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.pedido
    ADD CONSTRAINT fk_pedido_cliente FOREIGN KEY (id_cliente) REFERENCES ecommerce.cliente(id_cliente);


--
-- Name: produto fk_produto_categoria; Type: FK CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.produto
    ADD CONSTRAINT fk_produto_categoria FOREIGN KEY (id_categoria) REFERENCES ecommerce.categoria(id_categoria);


--
-- Name: forma_pagamento forma_pagamento_id_cliente_fkey; Type: FK CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.forma_pagamento
    ADD CONSTRAINT forma_pagamento_id_cliente_fkey FOREIGN KEY (id_cliente) REFERENCES ecommerce.cliente(id_cliente) ON DELETE CASCADE;


--
-- Name: item_pedido item_pedido_id_pedido_fkey; Type: FK CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.item_pedido
    ADD CONSTRAINT item_pedido_id_pedido_fkey FOREIGN KEY (id_pedido) REFERENCES ecommerce.pedido(id_pedido) ON DELETE CASCADE;


--
-- Name: item_pedido item_pedido_id_produto_fkey; Type: FK CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.item_pedido
    ADD CONSTRAINT item_pedido_id_produto_fkey FOREIGN KEY (id_produto) REFERENCES ecommerce.produto(id_produto);


--
-- Name: pagamento pagamento_id_forma_fkey; Type: FK CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.pagamento
    ADD CONSTRAINT pagamento_id_forma_fkey FOREIGN KEY (id_forma) REFERENCES ecommerce.forma_pagamento(id_forma);


--
-- Name: pagamento pagamento_id_pedido_fkey; Type: FK CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.pagamento
    ADD CONSTRAINT pagamento_id_pedido_fkey FOREIGN KEY (id_pedido) REFERENCES ecommerce.pedido(id_pedido) ON DELETE CASCADE;


--
-- Name: produto_fornecedor produto_fornecedor_id_fornecedor_fkey; Type: FK CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.produto_fornecedor
    ADD CONSTRAINT produto_fornecedor_id_fornecedor_fkey FOREIGN KEY (id_fornecedor) REFERENCES ecommerce.fornecedor(id_fornecedor);


--
-- Name: produto_fornecedor produto_fornecedor_id_produto_fkey; Type: FK CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.produto_fornecedor
    ADD CONSTRAINT produto_fornecedor_id_produto_fkey FOREIGN KEY (id_produto) REFERENCES ecommerce.produto(id_produto) ON DELETE CASCADE;


--
-- Name: produto_vendedor produto_vendedor_id_produto_fkey; Type: FK CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.produto_vendedor
    ADD CONSTRAINT produto_vendedor_id_produto_fkey FOREIGN KEY (id_produto) REFERENCES ecommerce.produto(id_produto) ON DELETE CASCADE;


--
-- Name: produto_vendedor produto_vendedor_id_vendedor_fkey; Type: FK CONSTRAINT; Schema: ecommerce; Owner: postgres
--

ALTER TABLE ONLY ecommerce.produto_vendedor
    ADD CONSTRAINT produto_vendedor_id_vendedor_fkey FOREIGN KEY (id_vendedor) REFERENCES ecommerce.vendedor_terceiro(id_vendedor);


--
-- PostgreSQL database dump complete
--

\unrestrict yKKH5atkKNmZoXZ7qhJFjPA84JoqaTlVrriPBwZdEftbEcJaTc3qaD2hP0fo42J

