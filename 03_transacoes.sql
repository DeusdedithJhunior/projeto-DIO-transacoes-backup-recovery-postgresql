-- =====================================================================
-- 03_transacoes.sql
-- PARTE 1 – Transações explícitas sem procedure (schema ecommerce)
-- PostgreSQL 14+
--
-- Pré-requisito: 02_ecommerce_schema.sql já executado.
-- O script pode ser reexecutado: cada execução cria um novo pedido na
-- transação 1 e outro na transação 3 e baixa poucas unidades de estoque.
--
-- ---------------------------------------------------------------------
-- COMO O AUTOCOMMIT FUNCIONA NO POSTGRESQL
-- ---------------------------------------------------------------------
-- No PostgreSQL o servidor trabalha sempre em "autocommit": todo comando
-- executado fora de um bloco BEGIN ... COMMIT/ROLLBACK é uma transação
-- própria e é confirmado sozinho assim que termina. Para agrupar vários
-- comandos numa única unidade (tudo ou nada) abre-se a transação com
-- BEGIN (ou START TRANSACTION) e encerra-se com COMMIT ou ROLLBACK.
--
-- No MySQL o desafio pede SET autocommit = 0. O PostgreSQL não tem essa
-- variável no servidor; o comportamento equivalente fica no cliente:
--   - psql:    \set AUTOCOMMIT off
--              (o psql passa a enviar um BEGIN implícito antes do
--               primeiro comando, e nada é gravado até um COMMIT)
--   - DBeaver: botão/atalho de modo de transação → "Manual Commit"
--              (o DBeaver abre a transação e mostra os botões
--               Commit/Rollback na barra de ferramentas)
-- Este script usa BEGIN/COMMIT/ROLLBACK explícitos, por isso deve ser
-- executado com o cliente em modo autocommit (padrão do psql e do
-- DBeaver em "Auto-Commit").
--
-- Observação importante: sequências (IDENTITY/SERIAL) NÃO voltam atrás
-- no ROLLBACK. Um id_pedido gerado numa transação desfeita é "perdido"
-- e o próximo pedido pula esse número. Isso é esperado.
-- =====================================================================

SET search_path TO ecommerce;

-- =====================================================================
-- TRANSAÇÃO 1 – Registrar pedido com itens e baixar estoque (COMMIT)
-- Cliente 5 compra 2 mouses (produto 5) e 3 cadernos (produto 11),
-- com saída do estoque do CD São Luís (local 1).
-- =====================================================================

-- ANTES: estoque dos produtos e total de pedidos
SELECT 'T1 antes' AS momento, e.id_produto, p.nome, e.id_local, e.quantidade
FROM estoque e JOIN produto p USING (id_produto)
WHERE e.id_local = 1 AND e.id_produto IN (5, 11)
ORDER BY e.id_produto;

SELECT 'T1 antes' AS momento, COUNT(*) AS total_pedidos FROM pedido;

BEGIN;

    INSERT INTO pedido (id_cliente, status, descricao, frete)
    VALUES (5, 'Confirmado', 'Transação 1 - COMMIT', 12.00);

    -- currval() devolve o id gerado pelo INSERT acima nesta mesma sessão
    INSERT INTO item_pedido (id_pedido, id_produto, quantidade, valor_unitario)
    SELECT currval(pg_get_serial_sequence('ecommerce.pedido', 'id_pedido')),
           p.id_produto, v.qtd, p.valor
    FROM (VALUES (5, 2), (11, 3)) AS v (id_produto, qtd)
    JOIN produto p ON p.id_produto = v.id_produto;

    UPDATE estoque e
       SET quantidade = e.quantidade - v.qtd
      FROM (VALUES (5, 2), (11, 3)) AS v (id_produto, qtd)
     WHERE e.id_produto = v.id_produto
       AND e.id_local = 1;

COMMIT;

-- DEPOIS: estoque reduzido e o novo pedido gravado com os itens
SELECT 'T1 depois' AS momento, e.id_produto, p.nome, e.id_local, e.quantidade
FROM estoque e JOIN produto p USING (id_produto)
WHERE e.id_local = 1 AND e.id_produto IN (5, 11)
ORDER BY e.id_produto;

SELECT 'T1 depois' AS momento, pe.id_pedido, pe.descricao, i.id_produto, i.quantidade, i.valor_unitario
FROM pedido pe JOIN item_pedido i USING (id_pedido)
WHERE pe.id_pedido = (SELECT MAX(id_pedido) FROM pedido WHERE descricao = 'Transação 1 - COMMIT')
ORDER BY i.id_produto;


-- =====================================================================
-- TRANSAÇÃO 2 – ROLLBACK total
-- Um pedido de 1 notebook (produto 4) e 1 monitor (produto 7) é montado,
-- mas a transação é desfeita: nada fica gravado.
-- =====================================================================

-- ANTES
SELECT 'T2 antes' AS momento, COUNT(*) AS total_pedidos FROM pedido;

SELECT 'T2 antes' AS momento, e.id_produto, e.id_local, e.quantidade
FROM estoque e
WHERE (e.id_produto, e.id_local) IN ((4, 1), (7, 3))
ORDER BY e.id_produto;

BEGIN;

    INSERT INTO pedido (id_cliente, status, descricao, frete)
    VALUES (2, 'Em processamento', 'Transação 2 - ROLLBACK', 25.00);

    INSERT INTO item_pedido (id_pedido, id_produto, quantidade, valor_unitario)
    SELECT currval(pg_get_serial_sequence('ecommerce.pedido', 'id_pedido')),
           p.id_produto, 1, p.valor
    FROM produto p
    WHERE p.id_produto IN (4, 7);

    UPDATE estoque SET quantidade = quantidade - 1 WHERE id_produto = 4 AND id_local = 1;
    UPDATE estoque SET quantidade = quantidade - 1 WHERE id_produto = 7 AND id_local = 3;

    -- DENTRO da transação as alterações são visíveis para esta sessão
    SELECT 'T2 dentro (antes do ROLLBACK)' AS momento, COUNT(*) AS pedidos_rollback
    FROM pedido WHERE descricao = 'Transação 2 - ROLLBACK';

ROLLBACK;

-- DEPOIS: total de pedidos e estoque iguais aos de antes
SELECT 'T2 depois' AS momento, COUNT(*) AS total_pedidos FROM pedido;

SELECT 'T2 depois' AS momento, COUNT(*) AS pedidos_rollback
FROM pedido WHERE descricao = 'Transação 2 - ROLLBACK';   -- deve ser 0

SELECT 'T2 depois' AS momento, e.id_produto, e.id_local, e.quantidade
FROM estoque e
WHERE (e.id_produto, e.id_local) IN ((4, 1), (7, 3))
ORDER BY e.id_produto;


-- =====================================================================
-- TRANSAÇÃO 3 – SAVEPOINT e ROLLBACK TO SAVEPOINT (desfaz só uma parte)
-- Cliente 3 compra uma Air Fryer (produto 8). Depois acrescenta um jogo
-- de panelas (produto 9), mas desiste só desse item: volta-se ao
-- savepoint, e o pedido com a Air Fryer é confirmado.
--
-- Dica: no PostgreSQL, se qualquer comando falhar dentro de uma
-- transação, ela fica "abortada" e só aceita ROLLBACK. Um
-- ROLLBACK TO SAVEPOINT recupera a transação a partir daquele ponto.
-- =====================================================================

-- ANTES
SELECT 'T3 antes' AS momento, e.id_produto, e.id_local, e.quantidade
FROM estoque e
WHERE (e.id_produto, e.id_local) IN ((8, 1), (9, 2))
ORDER BY e.id_produto;

BEGIN;

    -- Parte que será mantida
    INSERT INTO pedido (id_cliente, status, descricao, frete)
    VALUES (3, 'Confirmado', 'Transação 3 - SAVEPOINT', 18.50);

    INSERT INTO item_pedido (id_pedido, id_produto, quantidade, valor_unitario)
    SELECT currval(pg_get_serial_sequence('ecommerce.pedido', 'id_pedido')), id_produto, 1, valor
    FROM produto WHERE id_produto = 8;

    UPDATE estoque SET quantidade = quantidade - 1 WHERE id_produto = 8 AND id_local = 1;

    SAVEPOINT sp_item_extra;

    -- Parte que será desfeita
    INSERT INTO item_pedido (id_pedido, id_produto, quantidade, valor_unitario)
    SELECT currval(pg_get_serial_sequence('ecommerce.pedido', 'id_pedido')), id_produto, 1, valor
    FROM produto WHERE id_produto = 9;

    UPDATE estoque SET quantidade = quantidade - 1 WHERE id_produto = 9 AND id_local = 2;

    SELECT 'T3 dentro (antes do ROLLBACK TO)' AS momento, i.id_produto, i.quantidade
    FROM item_pedido i
    WHERE i.id_pedido = currval(pg_get_serial_sequence('ecommerce.pedido', 'id_pedido'))
    ORDER BY i.id_produto;

    ROLLBACK TO SAVEPOINT sp_item_extra;   -- desfaz só o item 9 e a baixa dele
    RELEASE SAVEPOINT sp_item_extra;

COMMIT;

-- DEPOIS: o pedido tem só a Air Fryer; estoque do produto 9 não mudou
SELECT 'T3 depois' AS momento, pe.id_pedido, i.id_produto, p.nome, i.quantidade
FROM pedido pe
JOIN item_pedido i USING (id_pedido)
JOIN produto p USING (id_produto)
WHERE pe.id_pedido = (SELECT MAX(id_pedido) FROM pedido WHERE descricao = 'Transação 3 - SAVEPOINT');

SELECT 'T3 depois' AS momento, e.id_produto, e.id_local, e.quantidade
FROM estoque e
WHERE (e.id_produto, e.id_local) IN ((8, 1), (9, 2))
ORDER BY e.id_produto;
