#!/usr/bin/env bash
# =====================================================================
# restore.sh – Recovery do backup do schema ecommerce num database novo
# (Git Bash no Windows ou Linux)
#
# Passos:
#   1. apaga o database de destino, se existir (padrão: ecommerce_restore)
#   2. cria o database vazio
#   3. restaura backups/ecommerce.dump com pg_restore
#   4. roda 07_validacao_recovery.sql (contagens, procedures, triggers)
#
# Uso:
#   export PGPASSWORD='sua_senha'   # ou configure o pgpass (ver README)
#   ./restore.sh                    # usa backups/ecommerce.dump
#   ./restore.sh backups/outro.dump # outro arquivo .dump do ecommerce
# =====================================================================
set -euo pipefail

# ---------------------------------------------------------------------
# Conexão – ajuste aqui (ou sobrescreva com variáveis de ambiente).
# A SENHA NÃO DEVE SER ESCRITA NESTE ARQUIVO: use PGPASSWORD ou pgpass.
# ---------------------------------------------------------------------
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-postgres}"
DB_MAINT="${DB_MAINT:-postgres}"                 # database usado só para conectar
RESTORE_DB="${RESTORE_DB:-ecommerce_restore}"    # database que será criado

DUMP_FILE="${1:-backups/ecommerce.dump}"
VALIDACAO="07_validacao_recovery.sql"

export PGCLIENTENCODING="${PGCLIENTENCODING:-UTF8}"

cd "$(dirname "${BASH_SOURCE[0]}")"

CONN=(-h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -w)   # -w: nunca pedir senha

# ---------------------------------------------------------------------
# Verificações
# ---------------------------------------------------------------------
for cmd in pg_restore psql dropdb createdb; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERRO: '$cmd' não encontrado no PATH."
        echo "No Git Bash, adicione a pasta bin do PostgreSQL, por exemplo:"
        echo '  export PATH="$PATH:/c/Program Files/PostgreSQL/16/bin"'
        exit 1
    fi
done

if [ ! -f "$DUMP_FILE" ]; then
    echo "ERRO: arquivo '$DUMP_FILE' não encontrado. Rode ./backup.sh antes."
    exit 1
fi

if ! psql "${CONN[@]}" -d "$DB_MAINT" -X -q -t -c "SELECT 1" >/dev/null; then
    echo "ERRO: não foi possível conectar em $DB_USER@$DB_HOST:$DB_PORT/$DB_MAINT."
    echo "Defina a senha antes de rodar (export PGPASSWORD='...') ou configure o pgpass."
    exit 1
fi

echo "Recovery de $DUMP_FILE em '$RESTORE_DB' ($DB_USER@$DB_HOST:$DB_PORT)"
echo

# ---------------------------------------------------------------------
# 1 e 2. Recria o database de destino
# (feche no DBeaver qualquer conexão aberta com ele antes de rodar)
# ---------------------------------------------------------------------
echo "[1] Removendo '$RESTORE_DB' (se existir)..."
dropdb "${CONN[@]}" --maintenance-db="$DB_MAINT" --if-exists "$RESTORE_DB"

echo "[2] Criando '$RESTORE_DB'..."
createdb "${CONN[@]}" --maintenance-db="$DB_MAINT" "$RESTORE_DB"

# ---------------------------------------------------------------------
# 3. Restaura. --no-owner/--no-privileges: os objetos ficam com o
#    usuário que restaura, evitando erro se o dono original não existir.
# ---------------------------------------------------------------------
echo "[3] Restaurando com pg_restore..."
pg_restore "${CONN[@]}" -d "$RESTORE_DB" --no-owner --no-privileges --exit-on-error "$DUMP_FILE"

# ---------------------------------------------------------------------
# 4. Validação
# ---------------------------------------------------------------------
echo "[4] Validando com $VALIDACAO..."
echo
psql "${CONN[@]}" -d "$RESTORE_DB" -X -v ON_ERROR_STOP=1 -f "$VALIDACAO"

echo
echo "Recovery concluído em '$RESTORE_DB'."
