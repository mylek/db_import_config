#!/usr/bin/env bash
# =============================================================================
# generate_sql.sh
#
# Generuje polecenia SQL UPDATE dla tabeli core_config_data
# na podstawie wybranej konfiguracji z pliku config.json.
#
# Klucz "_shared" jest ładowany automatycznie jako baza — każda konfiguracja
# może nadpisać jego wartości podając ten sam path (i opcjonalnie scope_id).
#
# Konfiguracje środowisk mogą używać sekcji "_web_urls" zamiast ręcznego
# wypisywania wszystkich wpisów URL. Format:
#
#   "_web_urls": {
#     "base": "https://example.com/",          <- bazowy URL (wymagany)
#     "scopes": [                              <- mapowanie scope_id → sufiks
#       { "ids": [0, 2], "suffix": "" },       <- domyślne jeśli pominięte
#       { "ids": [1],    "suffix": "en/" },
#       { "ids": [3],    "suffix": "pl/" }
#     ],
#     "static_url": "https://cdn.example.com/static/",  <- opcjonalne nadpisanie
#     "media_url":  "https://cdn.example.com/media/"    <- opcjonalne nadpisanie
#   }
#
# Skrypt auto-generuje wpisy dla:
#   web/unsecure/base_url, web/secure/base_url,
#   web/unsecure/base_link_url, web/secure/base_link_url  (filtrowane po scope_id)
#   web/unsecure/base_static_url, web/secure/base_static_url  (bez filtra scope_id)
#   web/unsecure/base_media_url,  web/secure/base_media_url   (bez filtra scope_id)
#
# Wpisy w "_shared" i "entries" mogą pominąć pole "scope" — brak pola oznacza
# UPDATE bez filtrowania po scope_id (odpowiednik scope = 'default' w Magento).
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
    if not key.startswith('_'):
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
        if not key.startswith('_'):
            print(f"  - {key}", file=sys.stderr)
    sys.exit(1)

URL_PATHS = [
    "web/unsecure/base_url",
    "web/secure/base_url",
    "web/unsecure/base_link_url",
    "web/secure/base_link_url",
]

DEFAULT_SCOPES = [
    { "ids": [0, 2], "suffix": "" },
    { "ids": [1],    "suffix": "en/" },
    { "ids": [3],    "suffix": "pl/" },
]

def expand_web_urls(cfg):
    """Rozwiń sekcję _web_urls na listę wpisów scope+path+value."""
    entries = []
    base = cfg["base"]
    for group in cfg.get("scopes", DEFAULT_SCOPES):
        url = base + group.get("suffix", "")
        for scope_id in group["ids"]:
            for path in URL_PATHS:
                entries.append({"scope": scope_id, "path": path, "value": url})
    static_url = cfg.get("static_url", base + "static/")
    media_url  = cfg.get("media_url",  base + "media/")
    for path in ["web/unsecure/base_static_url", "web/secure/base_static_url"]:
        entries.append({"scope": None, "path": path, "value": static_url})
    for path in ["web/unsecure/base_media_url", "web/secure/base_media_url"]:
        entries.append({"scope": None, "path": path, "value": media_url})
    return entries

def get_entries(config_value):
    """Zwróć listę wpisów z konfiguracji — obsługuje stary format (lista)
    oraz nowy format (obiekt z _web_urls i/lub entries)."""
    if isinstance(config_value, list):
        return config_value
    entries = []
    if "_web_urls" in config_value:
        entries += expand_web_urls(config_value["_web_urls"])
    entries += config_value.get("entries", [])
    return entries

# Załaduj _shared jako bazę (klucz: (scope, path) -> value)
merged = OrderedDict()
for entry in get_entries(all_configs.get("_shared", [])):
    key = (entry.get("scope"), entry["path"])
    merged[key] = entry["value"]

# Nadpisz/dodaj wartości z wybranej konfiguracji
for entry in get_entries(all_configs[config_key]):
    key = (entry.get("scope"), entry["path"])
    merged[key] = entry["value"]

# Grupuj wpisy o tej samej wartości i scope w jedno polecenie path in (...)
groups = OrderedDict()
for (scope, path), value in merged.items():
    group_key = (scope, value)
    if group_key not in groups:
        groups[group_key] = []
    groups[group_key].append(path)

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

SQL_FILE="${SCRIPT_DIR}/update.sql"

echo "$SQL_OUTPUT"
echo "$SQL_OUTPUT" > "$SQL_FILE"
echo "" >&2
echo "✓ Zapisano do: ${SQL_FILE}" >&2

if [[ -n "$CLIPBOARD_CMD" ]]; then
    echo "$SQL_OUTPUT" | eval "$CLIPBOARD_CMD"
    echo "✓ Skopiowano do schowka." >&2
else
    echo "" >&2
    echo "⚠ Nie znaleziono pbcopy/xclip/xsel — schowek niedostępny." >&2
fi
