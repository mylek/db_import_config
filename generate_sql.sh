#!/usr/bin/env bash
# =============================================================================
# generate_sql.sh
#
# Generuje polecenia SQL UPDATE dla tabeli core_config_data
# na podstawie wybranej konfiguracji z pliku config.json.
#
# Użycie:
#   ./generate_sql.sh <config_key>
#   ./generate_sql.sh nginx_htx
#
# Wymagania: python3
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.json"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "BŁĄD: Nie znaleziono pliku konfiguracyjnego: ${CONFIG_FILE}" >&2
    exit 1
fi

if [[ $# -ne 1 ]]; then
    echo "Użycie: $(basename "$0") <config_key>" >&2
    echo "" >&2
    echo "Dostępne konfiguracje:" >&2
    python3 -c "
import json, sys
with open('${CONFIG_FILE}') as f:
    cfg = json.load(f)
for key in cfg:
    print(f'  - {key}')
" >&2
    exit 1
fi

# Kopiuj wynik do schowka (pbcopy na macOS, xclip/xsel na Linux)
if command -v pbcopy &>/dev/null; then
    CLIPBOARD_CMD="pbcopy"
elif command -v xclip &>/dev/null; then
    CLIPBOARD_CMD="xclip -selection clipboard"
elif command -v xsel &>/dev/null; then
    CLIPBOARD_CMD="xsel --clipboard --input"
else
    CLIPBOARD_CMD=""
fi

SQL_OUTPUT=$(python3 - "$1" "$CONFIG_FILE" << 'PYEOF'
import json
import sys
from collections import OrderedDict

config_key = sys.argv[1]
config_file = sys.argv[2]

with open(config_file) as f:
    all_configs = json.load(f)

if config_key not in all_configs:
    print(f"BŁĄD: Konfiguracja '{config_key}' nie istnieje.", file=sys.stderr)
    print("", file=sys.stderr)
    print("Dostępne konfiguracje:", file=sys.stderr)
    for key in all_configs:
        print(f"  - {key}", file=sys.stderr)
    sys.exit(1)

entries = all_configs[config_key]

# Grupuj wpisy o tej samej wartości i scope w jedno polecenie path in (...)
groups = OrderedDict()
for entry in entries:
    scope = entry["scope"]   # liczba lub null
    path  = entry["path"]
    value = entry["value"]
    key = (scope, value)
    if key not in groups:
        groups[key] = []
    groups[key].append(path)

for (scope, value), paths in groups.items():
    escaped   = value.replace("'", "''")
    paths_sql = ", ".join(f"'{p}'" for p in paths)
    stmt = f"UPDATE core_config_data SET value = '{escaped}' WHERE path in ({paths_sql})"
    if scope is not None:
        stmt += f" AND scope_id = {scope}"
    stmt += ";"
    print(stmt)
PYEOF
)

echo "$SQL_OUTPUT"

if [[ -n "$CLIPBOARD_CMD" ]]; then
    echo "$SQL_OUTPUT" | eval "$CLIPBOARD_CMD"
    echo "" >&2
    echo "✓ Skopiowano do schowka." >&2
else
    echo "" >&2
    echo "⚠ Nie znaleziono pbcopy/xclip/xsel — schowek niedostępny." >&2
fi
