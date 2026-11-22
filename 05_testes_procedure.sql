-- =====================================================================
-- 05_testes_procedure.sql
-- PARTE 2 – Testes da procedure ecommerce.sp_finalizar_pedido
-- PostgreSQL 14+
--
-- Pré-requisito: 02 e 04 executados.
-- Execute em modo AUTOCOMMIT (padrão do psql; "Auto-Commit" no DBeaver).
-- Cada CALL fica fora de BEGIN ... COMMIT, porque a procedure faz
-- COMMIT/ROLLBACK internamente.
-- Pode ser reexecutado: cada execução cria 2 pedidos novos (casos 1 e 3)
-- e baixa poucas unidades de estoque.
-- =====================================================================

SET search_path TO ecommerce;

-- Situação geral antes dos testes
SELECT 'antes dos testes' AS momento,
       (SELECT COUNT(*) FROM pedido)      AS pedidos,
       (SELECT COUNT(*) FROM item_pedido) AS itens,
       (SELECT COUNT(*) FROM pagamento)   AS pagamentos,
       (SELECT COUNT(*) FROM log_pedido)  AS logs;


-- =====================================================================
-- CASO 1 – SUCESSO
-- Cliente 1 (Ana) compra 1 fone (produto 1) e 1 mouse (produto 5) no
-- CD São Luís, pagando com o próprio cartão (forma 1).
-- =====================================================================
SELECT 'caso 1 antes' AS momento, id_produto, quantidade
FROM estoque WHERE id_local = 1 AND id_produto IN (1, 5) ORDER BY id_produto;

CALL sp_finalizar_pedido(
    p_id_cliente => 1,
    p_itens      => '[{"id_produto": 1, "quantidade": 1},
                      {"id_produto": 5, "quantidade": 1}]',
    p_id_forma   => 1,
    p_id_local   => 1,
    p_frete      => 15.00
);

-- Pedido confirmado, itens, pagamento aprovado e log da trigger
SELECT 'caso 1 depois' AS momento, pe.id_pedido, pe.status, pg.valor AS valor_pago, pg.status AS status_pagamento
FROM pedido pe
LEFT JOIN pagamento pg USING (id_pedido)
WHERE pe.id_pedido = (SELECT MAX(id_pedido) FROM pedido WHERE id_cliente = 1);

SELECT 'caso 1 depois' AS momento, id_produto, quantidade
FROM estoque WHERE id_local = 1 AND id_produto IN (1, 5) ORDER BY id_produto;

SELECT 'caso 1 log' AS momento, id_pedido, operacao, status_anterior, status_novo, detalhe
FROM log_pedido
WHERE id_pedido = (SELECT MAX(id_pedido) FROM pedido WHERE id_cliente = 1)
ORDER BY id_log;


-- =====================================================================
-- CASO 2 – ROLLBACK TOTAL (estoque insuficiente)
-- O primeiro item (produto 5) tem estoque e chega a ser inserido; o
-- segundo (produto 4, notebook) pede 999 unidades. A procedure faz
-- ROLLBACK e nada fica gravado: nem o pedido, nem o item 5, nem a baixa.
-- =====================================================================
SELECT 'caso 2 antes' AS momento,
       (SELECT COUNT(*) FROM pedido) AS pedidos,
       (SELECT quantidade FROM estoque WHERE id_produto = 5 AND id_local = 1) AS estoque_prod_5;

CALL sp_finalizar_pedido(
    p_id_cliente => 2,
    p_itens      => '[{"id_produto": 5, "quantidade": 1},
                      {"id_produto": 4, "quantidade": 999}]',
    p_id_forma   => 3,
    p_id_local   => 1,
    p_frete      => 25.00
);

-- Mesmos números de antes
SELECT 'caso 2 depois' AS momento,
       (SELECT COUNT(*) FROM pedido) AS pedidos,
       (SELECT quantidade FROM estoque WHERE id_produto = 5 AND id_local = 1) AS estoque_prod_5;


-- =====================================================================
-- CASO 3 – ROLLBACK PARCIAL (falha no pagamento)
-- Cliente 3 (Camila) compra 2 canetas (produto 12), mas informa a forma
-- de pagamento 1, que pertence à cliente 1. O bloco do pagamento é
-- desfeito; o pedido, o item e a baixa de estoque são mantidos, e o
-- pedido fica "Em processamento" aguardando novo pagamento.
-- =====================================================================
SELECT 'caso 3 antes' AS momento, id_produto, quantidade
FROM estoque WHERE id_local = 1 AND id_produto = 12;

CALL sp_finalizar_pedido(
    p_id_cliente => 3,
    p_itens      => '[{"id_produto": 12, "quantidade": 2}]',
    p_id_forma   => 1,
    p_id_local   => 1,
    p_frete      => 0
);

-- Pedido existe, sem pagamento, ainda "Em processamento"
SELECT 'caso 3 depois' AS momento, pe.id_pedido, pe.status,
       (SELECT COUNT(*) FROM item_pedido i WHERE i.id_pedido = pe.id_pedido) AS itens,
       (SELECT COUNT(*) FROM pagamento  g WHERE g.id_pedido = pe.id_pedido) AS pagamentos
FROM pedido pe
WHERE pe.id_pedido = (SELECT MAX(id_pedido) FROM pedido WHERE id_cliente = 3);

SELECT 'caso 3 depois' AS momento, id_produto, quantidade
FROM estoque WHERE id_local = 1 AND id_produto = 12;

-- No log: o INSERT do pedido e a falha do pagamento. O "UPDATE STATUS"
-- para Confirmado não aparece, porque foi desfeito junto com o bloco.
SELECT 'caso 3 log' AS momento, id_pedido, operacao, status_anterior, status_novo, detalhe
FROM log_pedido
WHERE id_pedido = (SELECT MAX(id_pedido) FROM pedido WHERE id_cliente = 3)
ORDER BY id_log;


-- Situação geral depois dos testes
SELECT 'depois dos testes' AS momento,
       (SELECT COUNT(*) FROM pedido)      AS pedidos,
       (SELECT COUNT(*) FROM item_pedido) AS itens,
       (SELECT COUNT(*) FROM pagamento)   AS pagamentos,
       (SELECT COUNT(*) FROM log_pedido)  AS logs;
