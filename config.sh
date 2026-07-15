#!/usr/bin/env bash
# Tiny dependency-free reader for config.yaml (see config.example.yaml).
#
# The config is the SINGLE SOURCE OF TRUTH for this box's machine-specific values
# (device IPs, storage paths, env). Scripts and docs reference it so nothing
# personal is hardcoded — which keeps the repo generic and publishable.
#
# Handles the simple flat schema only: top-level `section:` lines, then
# 2-space-indented `name: value` pairs, `#` comments (whole-line or inline).
# No arrays, no nesting beyond that. jq/yq/PyYAML are NOT required.
#
# Use as a CLI:
#     ./config.sh get devices phone           # -> <that device's IP>
#     ./config.sh get directories storage     # -> <your storage dir>
#     ./config.sh keys devices                 # -> one device name per line
#     ./config.sh export-env                    # STORAGE_DIR=... SCAFFOLD_DIR=... (for eval)
# Or source it and call cfg_get / cfg_keys / cfg_export_env.
set -euo pipefail

CONFIG_DIR="${CONFIG_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/config.yaml}"

_cfg_require() {
  if [ ! -f "$CONFIG_FILE" ]; then
    echo "!! no $CONFIG_FILE — copy the template first:" >&2
    echo "     cp $CONFIG_DIR/config.example.yaml $CONFIG_FILE  # then edit it" >&2
    return 1
  fi
}

# cfg_get <section> <key>  -> prints the value (empty + nonzero if absent)
cfg_get() {
  _cfg_require || return 1
  awk -v sect="$1" -v key="$2" '
    /^[[:space:]]*#/ { next }
    /^[^[:space:]#]/ { in_sect = ($0 ~ "^"sect":[[:space:]]*$"); next }
    in_sect && $0 ~ "^[[:space:]]+"key":" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "")
      sub(/[[:space:]]+#.*$/, "")            # strip inline comment
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      print; found=1; exit
    }
    END { if (!found) exit 3 }
  ' "$CONFIG_FILE"
}

# cfg_keys <section>  -> prints each key in that section, one per line
cfg_keys() {
  _cfg_require || return 1
  awk -v sect="$1" '
    /^[[:space:]]*#/ { next }
    /^[^[:space:]#]/ { in_sect = ($0 ~ "^"sect":[[:space:]]*$"); next }
    in_sect && /^[[:space:]]+[^[:space:]#]+:/ {
      k=$0; sub(/^[[:space:]]+/, "", k); sub(/:.*$/, "", k); print k
    }
  ' "$CONFIG_FILE"
}

# cfg_export_env  -> emit shell assignments the rest of the tooling relies on.
# STORAGE_DIR + SCAFFOLD_DIR feed docker-compose interpolation; every
# environment: entry is exported verbatim.
cfg_export_env() {
  _cfg_require || return 1
  local storage scaffold k v
  storage="$(cfg_get directories storage || true)"
  scaffold="$(cfg_get directories scaffold || true)"
  [ -n "$storage" ]  && printf 'STORAGE_DIR=%q\n'  "$storage"
  [ -n "$scaffold" ] && printf 'SCAFFOLD_DIR=%q\n' "$scaffold"
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    v="$(cfg_get environment "$k" || true)"
    printf '%s=%q\n' "$k" "$v"
  done < <(cfg_keys environment)
}

# CLI dispatch (only when run directly, not when sourced)
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    get)        shift; cfg_get "$@" ;;
    keys)       shift; cfg_keys "$@" ;;
    export-env) cfg_export_env ;;
    *) echo "usage: $0 {get <section> <key> | keys <section> | export-env}" >&2; exit 2 ;;
  esac
fi
