# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

Narzędzie do zarządzania konfiguracją Magento (`core_config_data`) w wielu środowiskach deweloperskich opartych na Warden. Generuje i wykonuje polecenia SQL UPDATE na podstawie deklaratywnego pliku `config.json`.

## Workflow

**Krok 1 — wygeneruj SQL:**
```bash
./generate_sql.sh <config_key>
# np. ./generate_sql.sh nginx_htx
```
Zapisuje wynik do `update.sql` i kopiuje do schowka.

**Krok 2 — wykonaj SQL:**
```bash
./execute_sql.sh <config_key> [database]
# np. ./execute_sql.sh nginx_htx
# np. ./execute_sql.sh nginx_htx magento2
```
Wymaga działającego środowiska Warden (`warden env up` w katalogu projektu).

**Wylistuj dostępne konfiguracje:**
```bash
python3 -c "import json; cfg=json.load(open('config.json')); [print(k) for k in cfg if not k.startswith('_')]"
```

## Architecture

### config.json structure

```
{
  "_shared": [ ... ]          // Wpisy bazowe dla wszystkich środowisk (API URLs, SMTP, Elasticsearch, reCAPTCHA)
  "<env_key>": {
    "_warden_dir": "...",     // Wymagany: ścieżka do katalogu projektu Warden
    "_db": "magento",         // Opcjonalny: nazwa bazy (domyślnie "magento")
    "_web_urls": { ... },     // Automatycznie generuje wpisy URL dla wszystkich scope
    "entries": [ ... ]        // Ręczne nadpisania wartości z _shared
  }
}
```

### Merge logic

1. `_shared` jest ładowany jako baza — klucz unikatowy to `(scope_id, path)`
2. Wpisy środowiska nadpisują `_shared` (ten sam klucz = nowa wartość)
3. Wpisy z tym samym `value` i `scope_id` są grupowane w jedno `WHERE path in (...)`

### `_web_urls` expansion

Sekcja `_web_urls` automatycznie generuje wpisy dla:
- `web/unsecure/base_url`, `web/secure/base_url`, `web/unsecure/base_link_url`, `web/secure/base_link_url` — per scope_id z sufiksem
- `web/unsecure/base_static_url`, `web/secure/base_static_url` — bez filtra scope_id
- `web/unsecure/base_media_url`, `web/secure/base_media_url` — bez filtra scope_id

Domyślne mapowanie scope_id → sufiks URL: `{0,2}→""`, `{1}→"en/"`, `{3}→"pl/"`. Można nadpisać przez `"scopes"` w `_web_urls`.

Wpisy bez pola `scope` generują UPDATE bez filtrowania `AND scope_id = X`.

## Requirements

- `python3`
- `warden` (tylko `execute_sql.sh`)
- `pbcopy` / `xclip` / `xsel` (opcjonalne, clipboard)
