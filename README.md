# Criando Transações, Executando Backup e Recovery de Banco de Dados

Desafio DIO: transações no PostgreSQL com COMMIT, ROLLBACK e SAVEPOINT, procedure em PL/pgSQL com tratamento de erro e rollback total ou parcial, e backup e recovery do banco de e-commerce com pg_dump e pg_restore, incluindo procedures, funções e triggers.

## Descrição

O desafio do curso de SQL da DIO tem três partes:

1. **Transações sem procedure**: consultas e modificações reais no banco de e-commerce dentro de transações explícitas, com confirmação (COMMIT), desfazimento total (ROLLBACK) e parcial (SAVEPOINT).
2. **Transação dentro de procedure**: uma procedure que executa uma operação de negócio em várias etapas, com verificação de erro e rollback total ou parcial.
3. **Backup e recovery**: backup do banco com rotinas e triggers e restauração num banco novo, com validação.

O curso usa MySQL; aqui tudo foi adaptado para PostgreSQL (veja a seção [Adaptação MySQL → PostgreSQL](#adaptação-mysql--postgresql)).

Os dois bancos dos desafios anteriores ficam no mesmo database, cada um no seu schema: `company` e `ecommerce`.

## Tecnologias

- PostgreSQL 14 ou superior
- PL/pgSQL
- DBeaver
- Git Bash (Windows) com `pg_dump`, `pg_restore`, `psql`, `createdb` e `dropdb`

## Estrutura dos arquivos

| Arquivo | Conteúdo |
|---|---|
| `01_company_schema.sql` | Schema `company` com dados (desafio anterior) |
| `02_ecommerce_schema.sql` | Schema `ecommerce` com dados (desafio anterior) |
| `03_transacoes.sql` | Parte 1: transações com COMMIT, ROLLBACK e SAVEPOINT |
| `04_procedure_transacao.sql` | Parte 2: tabela de log, trigger e procedure `sp_finalizar_pedido` |
| `05_testes_procedure.sql` | Parte 2: testes de sucesso, rollback total e rollback parcial |
| `backup.sh` | Parte 3: backup completo e por schema (custom `.dump` e texto `.sql`) |
| `restore.sh` | Parte 3: recovery do `ecommerce` no database `ecommerce_restore` |
| `07_validacao_recovery.sql` | Parte 3: validação do banco restaurado |
| `backups/` | Arquivos gerados pelo `backup.sh` |

## Ordem de execução

Os scripts SQL usam o database `dio` (ajuste se o seu tiver outro nome) e devem ser executados em **modo autocommit**, que é o padrão do psql e do DBeaver ("Auto-Commit").

```bash
psql -h localhost -U postgres -d dio -f 01_company_schema.sql
psql -h localhost -U postgres -d dio -f 02_ecommerce_schema.sql
psql -h localhost -U postgres -d dio -f 03_transacoes.sql
psql -h localhost -U postgres -d dio -f 04_procedure_transacao.sql
psql -h localhost -U postgres -d dio -f 05_testes_procedure.sql
./backup.sh
./restore.sh      # executa também o 07_validacao_recovery.sql
```

No DBeaver, abra cada arquivo e use **Execute SQL Script** (Alt+X).

Todos os scripts podem ser reexecutados. Os scripts 01 e 02 recriam os schemas do zero (o 02 também apaga a procedure, a trigger e a tabela de log do 04). Os scripts 03 e 05 criam alguns pedidos novos a cada execução.

## Parte 1 – Transações

### Autocommit no PostgreSQL

No PostgreSQL, todo comando executado fora de um bloco `BEGIN ... COMMIT/ROLLBACK` é uma transação própria e é confirmado sozinho. Para agrupar comandos numa unidade "tudo ou nada", abre-se a transação com `BEGIN` e fecha-se com `COMMIT` ou `ROLLBACK`.

Não existe `SET autocommit = 0` no servidor. O equivalente fica no cliente:

- **psql**: `\set AUTOCOMMIT off`
- **DBeaver**: modo de transação **Manual Commit**

### Transações do `03_transacoes.sql`

Cada transação tem SELECTs antes e depois que mostram o efeito.

| Transação | O que faz | Resultado |
|---|---|---|
| 1 – COMMIT | Insere pedido com 2 itens e baixa o estoque | Tudo gravado |
| 2 – ROLLBACK | Insere pedido, itens e baixa estoque, depois desfaz | Nada gravado: contagem de pedidos e estoque iguais aos de antes |
| 3 – SAVEPOINT | Insere pedido com 1 item, cria `SAVEPOINT`, adiciona um 2º item e volta com `ROLLBACK TO SAVEPOINT` | Pedido gravado só com o 1º item; estoque do 2º item intacto |

**Rollback total x parcial**: o `ROLLBACK` desfaz a transação inteira; o `ROLLBACK TO SAVEPOINT` desfaz só o que foi feito depois do savepoint e mantém a transação aberta para seguir até o `COMMIT`.

Observações:

- Sequências (`IDENTITY`) não voltam no rollback: o id gerado na transação 2 é perdido e o próximo pedido pula esse número.
- Se um comando falhar dentro de uma transação, o PostgreSQL marca a transação como abortada e só aceita `ROLLBACK` ou `ROLLBACK TO SAVEPOINT`.

## Parte 2 – Procedure com transação

O `04_procedure_transacao.sql` cria:

- `ecommerce.log_pedido`: histórico de inclusão e mudança de status dos pedidos;
- `ecommerce.fn_log_pedido()` e a trigger `trg_log_pedido` (AFTER INSERT OR UPDATE OF status em `pedido`);
- `ecommerce.sp_finalizar_pedido(...)`: finaliza um pedido em etapas.

```sql
CALL ecommerce.sp_finalizar_pedido(
    p_id_cliente => 1,
    p_itens      => '[{"id_produto": 1, "quantidade": 1}, {"id_produto": 5, "quantidade": 1}]',
    p_id_forma   => 1,     -- forma de pagamento do cliente
    p_id_local   => 1,     -- local de estoque
    p_frete      => 15.00
);
```

O CALL devolve `p_id_pedido`, `p_resultado` e `p_mensagem`.

### Etapas e tratamento de erro

1. Valida cliente e lista de itens.
2. Insere o pedido (`Em processamento`).
3. Para cada item: trava o estoque (`FOR UPDATE`), valida a quantidade, insere o item e baixa o estoque.
   - Produto inexistente, quantidade inválida ou estoque insuficiente → **ROLLBACK total**: a procedure executa `ROLLBACK`, que desfaz o pedido e os itens já inseridos, e devolve a mensagem do motivo.
4. Registra o pagamento e muda o status para `Confirmado` dentro de um bloco `BEGIN ... EXCEPTION`.
   - Forma de pagamento inexistente, inativa ou de outro cliente → **ROLLBACK parcial**: só o bloco é desfeito (pagamento, mudança de status e o log gerado pela trigger). Pedido, itens e baixa de estoque são mantidos, e um registro `PAGAMENTO FALHOU` vai para o log.
5. `COMMIT`.

Erros não previstos interrompem o CALL e o PostgreSQL desfaz automaticamente o que não foi confirmado.

### Regras de transação em PL/pgSQL

- PL/pgSQL **não aceita `SAVEPOINT`** explícito. O bloco `BEGIN ... EXCEPTION ... END` funciona como um savepoint implícito: um erro dentro dele desfaz só o que foi feito no bloco.
- `COMMIT` e `ROLLBACK` são permitidos em **procedure** (não em function), mas só quando o `CALL` é executado **fora de um bloco de transação**. Dentro de `BEGIN ... COMMIT`, com `\set AUTOCOMMIT off` ou no modo Manual Commit do DBeaver, o resultado é `ERROR: invalid transaction termination`.
- Não se pode usar `COMMIT`/`ROLLBACK` dentro de um bloco que tenha `EXCEPTION`. Por isso eles ficam no corpo principal da procedure.

### Testes (`05_testes_procedure.sql`)

| Caso | Entrada | Resultado esperado |
|---|---|---|
| Sucesso | Cliente 1, 2 itens com estoque, forma de pagamento própria | Pedido `Confirmado`, pagamento `Aprovado`, estoque baixado, 2 registros no log |
| Rollback total | Cliente 2, 2º item com 999 unidades | Nada gravado: contagem de pedidos e estoque do 1º item iguais aos de antes |
| Rollback parcial | Cliente 3 usando a forma de pagamento da cliente 1 | Pedido gravado `Em processamento`, com item e baixa de estoque, sem pagamento; log com `PAGAMENTO FALHOU` |

## Parte 3 – Backup e recovery

### Preparação no Windows (Git Bash)

1. **PATH**: se aparecer `pg_dump: command not found`, adicione a pasta `bin` do PostgreSQL (ajuste a versão):

   ```bash
   export PATH="$PATH:/c/Program Files/PostgreSQL/16/bin"
   ```

   Para deixar permanente, coloque essa linha no `~/.bashrc`.

2. **Senha**: os scripts não contêm senha e usam `-w` (nunca pedem senha no terminal). Use uma das opções:

   - variável de ambiente, só na sessão atual do terminal:

     ```bash
     export PGPASSWORD='sua_senha'
     ```

   - arquivo pgpass, em `%APPDATA%\postgresql\pgpass.conf` no Windows (`~/.pgpass` no Linux, com `chmod 600`):

     ```
     localhost:5432:*:postgres:sua_senha
     ```

3. **Conexão**: as variáveis `DB_HOST`, `DB_PORT`, `DB_USER` e `DB_NAME` ficam no topo de cada script. Também podem ser passadas na linha de comando, por exemplo `DB_NAME=meu_db ./backup.sh`.

### Backup

```bash
./backup.sh
```

Arquivos gerados em `backups/`:

| Arquivo | Conteúdo | Formato |
|---|---|---|
| `dio_completo.dump` | Database inteiro | custom (`pg_restore`) |
| `dio_completo.sql` | Database inteiro | texto (`psql`) |
| `ecommerce.dump` / `ecommerce.sql` | Só o schema `ecommerce` | custom / texto |
| `company.dump` / `company.sql` | Só o schema `company` | custom / texto |

Comandos usados pelo script:

```bash
pg_dump -h localhost -p 5432 -U postgres -w -d dio -Fc -f backups/dio_completo.dump
pg_dump -h localhost -p 5432 -U postgres -w -d dio -Fp -E UTF8 -f backups/dio_completo.sql
pg_dump -h localhost -p 5432 -U postgres -w -d dio -n ecommerce -Fc -f backups/ecommerce.dump
pg_dump -h localhost -p 5432 -U postgres -w -d dio -n company   -Fc -f backups/company.dump
```

Ao final, o script lista com `pg_restore -l` as funções, procedures e triggers encontradas em cada `.dump`, confirmando que foram incluídas no backup.

### Recovery

```bash
./restore.sh
```

O script:

1. apaga o database `ecommerce_restore`, se existir;
2. cria o database vazio;
3. restaura `backups/ecommerce.dump`;
4. executa `07_validacao_recovery.sql`.

Comandos equivalentes:

```bash
dropdb   -h localhost -U postgres -w --if-exists ecommerce_restore
createdb -h localhost -U postgres -w ecommerce_restore
pg_restore -h localhost -U postgres -w -d ecommerce_restore --no-owner --no-privileges --exit-on-error backups/ecommerce.dump
psql -h localhost -U postgres -w -d ecommerce_restore -f 07_validacao_recovery.sql
```

Feche no DBeaver qualquer conexão com `ecommerce_restore` antes de rodar, senão o `dropdb` falha.

Outras formas de restaurar:

```bash
# database inteiro (formato custom)
createdb -h localhost -U postgres dio_restore
pg_restore -h localhost -U postgres -d dio_restore --no-owner backups/dio_completo.dump

# arquivo texto (.sql)
createdb -h localhost -U postgres ecommerce_restore_sql
psql -h localhost -U postgres -d ecommerce_restore_sql -f backups/ecommerce.sql
```

### Validação (`07_validacao_recovery.sql`)

- database conectado e versão;
- contagem de registros por tabela (para comparar com a origem);
- total de tabelas, procedures, funções, triggers e constraints restauradas;
- sequências das colunas IDENTITY alinhadas com o maior id;
- teste da trigger com `UPDATE` dentro de uma transação que termina em `ROLLBACK` (não altera dados);
- amostra dos últimos pedidos.

## Adaptação MySQL → PostgreSQL

| Tema | MySQL | PostgreSQL |
|---|---|---|
| Desligar autocommit | `SET autocommit = 0;` | No cliente: `\set AUTOCOMMIT off` (psql) ou modo Manual Commit (DBeaver). Ou usar `BEGIN` explícito |
| Iniciar transação | `START TRANSACTION;` | `BEGIN;` ou `START TRANSACTION;` |
| Savepoint em script | `SAVEPOINT` / `ROLLBACK TO` | Igual |
| Savepoint em procedure | `SAVEPOINT` dentro da procedure | Não permitido. Usar bloco `BEGIN ... EXCEPTION` (savepoint implícito) |
| Tratamento de erro em procedure | `DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; END;` | `EXCEPTION WHEN OTHERS THEN ...` no bloco, ou `ROLLBACK` explícito no corpo principal |
| COMMIT/ROLLBACK em procedure | Permitido | Só se o `CALL` estiver fora de transação e fora de bloco com `EXCEPTION` |
| Backup lógico | `mysqldump` | `pg_dump` (um database) / `pg_dumpall` (cluster inteiro, incluindo usuários) |
| Restauração | `mysql < arquivo.sql` | `psql -f arquivo.sql` (texto) ou `pg_restore` (custom/tar/diretório) |
| `--routines` | Inclui procedures e funções | Não existe: funções e procedures já vêm por padrão |
| `--triggers` | Inclui triggers (padrão) | Não existe: triggers já vêm por padrão |
| `--events` | Inclui eventos agendados | Não há eventos nativos. O equivalente é a extensão **pg_cron** (os jobs ficam na tabela `cron.job`, no database onde a extensão foi instalada) ou um agendador externo (Agendador de Tarefas do Windows, cron) |
| `--databases db1 db2` | Vários bancos num arquivo | Um `pg_dump` por database ou por schema (`-n`), ou `pg_dumpall` |
| `--no-data` | Só estrutura | `--schema-only` (`-s`) |
| `--no-create-info` | Só dados | `--data-only` (`-a`) |
