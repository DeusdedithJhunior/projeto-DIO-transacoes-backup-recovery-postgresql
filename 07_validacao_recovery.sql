-- =====================================================================
-- 07_validacao_recovery.sql
-- PARTE 3 – Validação do recovery do schema ecommerce
-- PostgreSQL 14+
--
-- Executar conectado ao database restaurado (padrão: ecommerce_restore).
-- O restore.sh já chama este script ao final. Para rodar à mão:
--   psql -h localhost -U postgres -d ecommerce_restore -f 07_validacao_recovery.sql
-- No DBeaver: abra uma conexão apontando para o database ecommerce_restore.
--
-- Não altera dados: o teste da trigger termina em ROLLBACK.
-- Pode ser reexecutado quantas vezes quiser.
-- =====================================================================

SET search_path TO ecommerce;

-- 1. Onde estou conectado
SELECT current_database() AS database_atual, current_user AS usuario, version() AS versao;

-- 2. Contagem de registros por tabela
--    Compare com o mesmo SELECT executado no database de origem.
SELECT 'cliente' AS tabela, COUNT(*) AS registros FROM cliente
UNION ALL SELECT 'categoria',          COUNT(*) FROM categoria
UNION ALL SELECT 'produto',            COUNT(*) FROM produto
UNION ALL SELECT 'fornecedor',         COUNT(*) FROM fornecedor
UNION ALL SELECT 'produto_fornecedor', COUNT(*) FROM produto_fornecedor
UNION ALL SELECT 'vendedor_terceiro',  COUNT(*) FROM vendedor_terceiro
UNION ALL SELECT 'produto_vendedor',   COUNT(*) FROM produto_vendedor
UNION ALL SELECT 'local_estoque',      COUNT(*) FROM local_estoque
UNION ALL SELECT 'estoque',            COUNT(*) FROM estoque
UNION ALL SELECT 'pedido',             COUNT(*) FROM pedido
UNION ALL SELECT 'item_pedido',        COUNT(*) FROM item_pedido
UNION ALL SELECT 'forma_pagamento',    COUNT(*) FROM forma_pagamento
UNION ALL SELECT 'pagamento',          COUNT(*) FROM pagamento
UNION ALL SELECT 'entrega',            COUNT(*) FROM entrega
UNION ALL SELECT 'log_pedido',         COUNT(*) FROM log_pedido;

-- 3. Tabelas restauradas no schema (deve listar 15)
SELECT COUNT(*) AS total_tabelas
FROM information_schema.tables
WHERE table_schema = 'ecommerce' AND table_type = 'BASE TABLE';

-- 4. Procedures e funções restauradas
SELECT p.proname AS nome,
       CASE p.prokind WHEN 'p' THEN 'procedure' WHEN 'f' THEN 'function' ELSE p.prokind::text END AS tipo,
       pg_get_function_identity_arguments(p.oid) AS argumentos
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'ecommerce'
ORDER BY tipo, nome;

-- 5. Triggers restauradas
SELECT t.tgname AS trigger, t.tgrelid::regclass AS tabela,
       pg_get_triggerdef(t.oid) AS definicao
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'ecommerce' AND NOT t.tgisinternal
ORDER BY tabela, trigger;

-- 6. Constraints (PK, FK, UNIQUE, CHECK) por tipo
SELECT CASE con.contype WHEN 'p' THEN 'PRIMARY KEY' WHEN 'f' THEN 'FOREIGN KEY'
                        WHEN 'u' THEN 'UNIQUE'      WHEN 'c' THEN 'CHECK'
                        ELSE con.contype::text END AS tipo,
       COUNT(*) AS quantidade
FROM pg_constraint con
JOIN pg_namespace n ON n.oid = con.connamespace
WHERE n.nspname = 'ecommerce'
GROUP BY con.contype
ORDER BY tipo;

-- 7. Sequências das colunas IDENTITY: o último valor deve ser >= maior id,
--    senão o próximo INSERT tentaria reutilizar um id existente.
SELECT 'pedido' AS tabela,
       (SELECT MAX(id_pedido) FROM pedido) AS maior_id,
       (SELECT last_value FROM pg_sequences
         WHERE schemaname = 'ecommerce'
           AND sequencename = split_part(pg_get_serial_sequence('ecommerce.pedido', 'id_pedido'), '.', 2)) AS ultimo_valor_sequencia
UNION ALL
SELECT 'cliente',
       (SELECT MAX(id_cliente) FROM cliente),
       (SELECT last_value FROM pg_sequences
         WHERE schemaname = 'ecommerce'
           AND sequencename = split_part(pg_get_serial_sequence('ecommerce.cliente', 'id_cliente'), '.', 2));

-- 8. Teste funcional da trigger restaurada (sem gravar nada)
BEGIN;
    UPDATE pedido SET status = 'Cancelado'
    WHERE id_pedido = (SELECT MIN(id_pedido) FROM pedido WHERE status = 'Em processamento');

    SELECT 'teste trigger' AS teste, id_pedido, operacao, status_anterior, status_novo
    FROM log_pedido
    WHERE id_log = (SELECT MAX(id_log) FROM log_pedido);
ROLLBACK;

-- 9. Amostra de dados: últimos pedidos com cliente e valor
SELECT pe.id_pedido, c.nome AS cliente, pe.status, pe.data_pedido::date AS data,
       SUM(i.quantidade * i.valor_unitario) + pe.frete AS total
FROM pedido pe
JOIN cliente c USING (id_cliente)
JOIN item_pedido i USING (id_pedido)
GROUP BY pe.id_pedido, c.nome, pe.status, pe.data_pedido, pe.frete
ORDER BY pe.id_pedido DESC
LIMIT 5;
