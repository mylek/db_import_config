#!/usr/bin/env bash
# =============================================================================
# execute_sql.sh
#
# Wykonuje plik update.sql na bazie danych przez warden db connect.
# Katalog projektu warden oraz nazwa bazy są odczytywane z config.json
# na podstawie klucza środowiska.
#
# Użycie:
#   ./execute_sql.sh <config_key> [database]
#   ./execute_sql.sh nginx_htx             <- baza z config lub domyślnie "magento"
#   ./execute_sql.sh nginx_htx magento2    <- nadpisuje nazwę bazy
#
# Wymagania: warden, działające środowisko warden (warden env up)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.json"
SQL_FILE="${SCRIPT_DIR}/update.sql"

if [[ $# -lt 1 ]]; then
    echo "Użycie: $(basename "$0") <config_key> [database]" >&2
    echo "" >&2
    echo "Dostępne konfiguracje:" >&2
    python3 -c "
import json, sys
with open('${CONFIG_FILE}') as f:
    cfg = json.load(f)
for key in cfg:
    if not key.startswith('_'):
        print(f'  - {key}')
" >&2
    exit 1
fi

CONFIG_KEY="$1"
DATABASE_OVERRIDE="${2:-}"

if [[ ! -f "$SQL_FILE" ]]; then
    echo "BŁĄD: Nie znaleziono pliku ${SQL_FILE}" >&2
    echo "Najpierw uruchom: ./generate_sql.sh ${CONFIG_KEY}" >&2
    exit 1
fi

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

echo "" >&2
echo "✓ Gotowe." >&2
