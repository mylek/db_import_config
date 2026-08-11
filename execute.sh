#!/usr/bin/env bash
# =============================================================================
# execute.sh
#
# Kompleksowy skrypt wdrożenia środowiska Magento przez Warden:
#   1. Generuje update.sql z config.json (wywołuje generate_sql.sh)
#   2. Jeśli podano nazwę bazy — aktualizuje dbname w app/etc/env.php
#   3. Wykonuje update.sql na bazie danych przez warden env exec db
#   4. Wykonuje komendy zdefiniowane w _commands (config.json) przez php-fpm
#
# Wywołanie bez parametrów uruchamia tryb interaktywny — skrypt poprosi
# o wybór konfiguracji z listy i opcjonalnie o nazwę bazy danych.
#
# Użycie:
#   ./execute.sh                     <- tryb interaktywny
#   ./execute.sh <config_key>        <- baza z config lub domyślnie "magento"
#   ./execute.sh <config_key> <db>   <- nadpisuje nazwę bazy (aktualizuje env.php)
#
# Klucze config.json:
#   _warden_dir  — ścieżka do katalogu projektu Warden (wymagany)
#   _db          — nazwa bazy danych (opcjonalny, domyślnie "magento")
#   _commands    — lista komend wykonywanych po SQL przez php-fpm (opcjonalny)
#
# Wymagania: python3, warden (warden env up przed uruchomieniem)
# =============================================================================

set -euo pipefail

START_TIME=$(date +%s)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.json"
SQL_FILE="${SCRIPT_DIR}/update.sql"

if [[ $# -lt 1 ]]; then
    CONFIGS=$(python3 -c "
import json
with open('${CONFIG_FILE}') as f:
    cfg = json.load(f)
for key in cfg:
    if not key.startswith('_'):
        print(key)
")

    echo "Wybierz konfigurację:" >&2
    select CONFIG_KEY in $CONFIGS; do
        [[ -n "$CONFIG_KEY" ]] && break
        echo "Nieprawidłowy wybór, spróbuj ponownie." >&2
    done

    read -rp "Nazwa bazy danych [magento]: " DATABASE_OVERRIDE
    DATABASE_OVERRIDE="${DATABASE_OVERRIDE:-}"
else
    CONFIG_KEY="$1"
    DATABASE_OVERRIDE="${2:-}"
fi

echo "Generuję SQL dla: ${CONFIG_KEY}" >&2
"${SCRIPT_DIR}/generate_sql.sh" "${CONFIG_KEY}"

if ! command -v warden &>/dev/null; then
    echo "BŁĄD: Komenda 'warden' nie jest dostępna." >&2
    exit 1
fi

# Odczytaj warden_dir i db z config.json
read -r WARDEN_DIR DATABASE < <(python3 - "$CONFIG_KEY" "$DATABASE_OVERRIDE" "$CONFIG_FILE" << 'PYEOF'
import json, sys

config_key     = sys.argv[1]
db_override    = sys.argv[2]
config_file    = sys.argv[3]

with open(config_file) as f:
    all_configs = json.load(f)

if config_key not in all_configs:
    print(f"BŁĄD: Konfiguracja '{config_key}' nie istnieje.", file=sys.stderr)
    sys.exit(1)

cfg          = all_configs[config_key]
warden_dir   = cfg.get("_warden_dir", "")
database     = db_override or cfg.get("_db", "magento")

if not warden_dir:
    print(f"BŁĄD: Brak '_warden_dir' w konfiguracji '{config_key}'.", file=sys.stderr)
    sys.exit(1)

print(warden_dir, database)
PYEOF
)

if [[ ! -d "$WARDEN_DIR" ]]; then
    echo "BŁĄD: Katalog '${WARDEN_DIR}' nie istnieje." >&2
    exit 1
fi

if [[ -n "$DATABASE_OVERRIDE" ]]; then
    ENV_PHP="${WARDEN_DIR}/app/etc/env.php"
    if [[ -f "$ENV_PHP" ]]; then
        python3 - "$ENV_PHP" "$DATABASE_OVERRIDE" << 'PYEOF'
import re, sys
path, dbname = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()
updated = re.sub(r"('dbname'\s*=>\s*')[^']*(')", rf"\g<1>{dbname}\2", content)
with open(path, 'w') as f:
    f.write(updated)
PYEOF
        echo "Zaktualizowano dbname w app/etc/env.php → ${DATABASE_OVERRIDE}" >&2
    else
        echo "⚠ Nie znaleziono ${ENV_PHP}" >&2
    fi
fi

echo "Środowisko : ${CONFIG_KEY}" >&2
echo "Katalog    : ${WARDEN_DIR}" >&2
echo "Baza danych: ${DATABASE}" >&2
echo "" >&2

TMP_SQL=$(mktemp /tmp/warden_execute_XXXXXX.sql)
trap "rm -f ${TMP_SQL}" EXIT

printf 'USE `%s`;\n' "${DATABASE}" > "${TMP_SQL}"
cat "${SQL_FILE}" >> "${TMP_SQL}"

cd "$WARDEN_DIR"
warden env exec -T -- db bash -c "mysql -uroot -p\${MYSQL_ROOT_PASSWORD} ${DATABASE}" < "${TMP_SQL}"

# Odczytaj komendy do wykonania (_commands z top-level + z wybranego środowiska)
COMMANDS=$(python3 - "$CONFIG_KEY" "$CONFIG_FILE" << 'PYEOF'
import json, sys

config_key  = sys.argv[1]
config_file = sys.argv[2]

with open(config_file) as f:
    all_configs = json.load(f)

shared_cmds = all_configs.get("_commands", [])
env_cfg     = all_configs.get(config_key, {})
env_cmds    = env_cfg.get("_commands", []) if isinstance(env_cfg, dict) else []

for cmd in shared_cmds + env_cmds:
    print(cmd)
PYEOF
)

if [[ -n "$COMMANDS" ]]; then
    echo "" >&2
    echo "Wykonuję komendy:" >&2
    while IFS= read -r cmd; do
        echo "  \$ ${cmd}" >&2
        warden env exec -T -- php-fpm bash -c "cd /var/www/html && ${cmd}" < /dev/null
    done <<< "$COMMANDS"
fi

ELAPSED=$(( $(date +%s) - START_TIME ))
echo "" >&2
echo "✓ Gotowe. Czas wykonania: $(( ELAPSED / 60 ))m $(( ELAPSED % 60 ))s" >&2
