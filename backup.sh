#!/usr/bin/env bash
# =====================================================================
# backup.sh – Backup do database com pg_dump (Git Bash no Windows ou Linux)
#
# Gera em backups/:
#   <db>_completo.dump  database inteiro, formato custom (pg_restore)
#   <db>_completo.sql   database inteiro, formato texto (psql)
#   ecommerce.dump/.sql apenas o schema ecommerce
#   company.dump/.sql   apenas o schema company
#
# Funções, procedures e triggers já entram no pg_dump por padrão
# (não há opção equivalente a --routines/--triggers do mysqldump).
#
# Uso:
#   export PGPASSWORD='sua_senha'   # ou configure o pgpass (ver README)
#   ./backup.sh
# =====================================================================
set -euo pipefail

# ---------------------------------------------------------------------
# Conexão – ajuste aqui (ou sobrescreva com variáveis de ambiente).
# A SENHA NÃO DEVE SER ESCRITA NESTE ARQUIVO: use PGPASSWORD ou pgpass.
# ---------------------------------------------------------------------
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-postgres}"
DB_NAME="${DB_NAME:-dio}"

SCHEMAS=("ecommerce" "company")
BACKUP_DIR="backups"

# Saída do psql com acentos corretos no terminal do Git Bash
export PGCLIENTENCODING="${PGCLIENTENCODING:-UTF8}"

# Trabalha sempre a partir da pasta do script (caminhos relativos
# evitam problemas de conversão de caminho no Git Bash)
cd "$(dirname "${BASH_SOURCE[0]}")"

CONN=(-h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -w)   # -w: nunca pedir senha

# ---------------------------------------------------------------------
# Verificações
# ---------------------------------------------------------------------
for cmd in pg_dump pg_restore psql; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERRO: '$cmd' não encontrado no PATH."
        echo "No Git Bash, adicione a pasta bin do PostgreSQL, por exemplo:"
        echo '  export PATH="$PATH:/c/Program Files/PostgreSQL/16/bin"'
        exit 1
    fi
done

if ! psql "${CONN[@]}" -d "$DB_NAME" -X -q -t -c "SELECT 1" >/dev/null; then
    echo "ERRO: não foi possível conectar em $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME."
    echo "Defina a senha antes de rodar (export PGPASSWORD='...') ou configure o pgpass."
    exit 1
fi

mkdir -p "$BACKUP_DIR"
echo "Backup de '$DB_NAME' ($DB_USER@$DB_HOST:$DB_PORT) em $BACKUP_DIR/"
echo "pg_dump: $(pg_dump --version)"
echo

# ---------------------------------------------------------------------
# 1. Backup completo do database
# ---------------------------------------------------------------------
echo "[1] Database completo..."
pg_dump "${CONN[@]}" -d "$DB_NAME" -Fc         -f "$BACKUP_DIR/${DB_NAME}_completo.dump"
pg_dump "${CONN[@]}" -d "$DB_NAME" -Fp -E UTF8 -f "$BACKUP_DIR/${DB_NAME}_completo.sql"

# ---------------------------------------------------------------------
# 2. Backup separado de cada schema ("diferentes bancos")
# ---------------------------------------------------------------------
for schema in "${SCHEMAS[@]}"; do
    echo "[2] Schema $schema..."
    pg_dump "${CONN[@]}" -d "$DB_NAME" -n "$schema" -Fc         -f "$BACKUP_DIR/${schema}.dump"
    pg_dump "${CONN[@]}" -d "$DB_NAME" -n "$schema" -Fp -E UTF8 -f "$BACKUP_DIR/${schema}.sql"
done

# ---------------------------------------------------------------------
# 3. Conferência: funções, procedures e triggers dentro dos dumps
#    (pg_restore -l lista o conteúdo de um arquivo .dump)
# ---------------------------------------------------------------------
echo
for arquivo in "$BACKUP_DIR/${DB_NAME}_completo.dump" "$BACKUP_DIR"/ecommerce.dump "$BACKUP_DIR"/company.dump; do
    echo "== Conteúdo de $arquivo"
    pg_restore -l "$arquivo" | awk '
        / TABLE DATA /  { dados++ }
        / TABLE /       && !/ TABLE DATA / { tabelas++ }
        / FUNCTION /    { print "   " $0 }
        / PROCEDURE /   { print "   " $0 }
        / TRIGGER /     { print "   " $0 }
        END { printf "   tabelas: %d | tabelas com dados: %d\n", tabelas, dados }'
done

echo
echo "Arquivos gerados:"
ls -lh "$BACKUP_DIR"
echo
echo "Backup concluído."
