#!/usr/bin/env bash
# Regenerate the F-Droid repo's metadata/ from the BAM Store's index.json.
#
# Thin path-resolving wrapper around scripts/fdroid_metadata.py: the store dir
# and the fdroid repo dir come from config.yaml, everything else is that
# script's job (see its docstring for the merge/icon rules).
#
# Usage: scripts/fdroid-metadata.sh
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../config.sh
source "$ROOT/config.sh"

REPO_DIR="${FDROID_REPO:-$(cfg_get directories fdroid-repo || true)}"
STORE="${BAM_STORE:-$(cfg_get directories bam-store || true)}"
STORE="${STORE:-$ROOT/store}"
AUTHOR="${FDROID_AUTHOR:-$(cfg_get fdroid author || true)}"

if [ -z "$REPO_DIR" ]; then
  echo "!! directories.fdroid-repo is not set in config.yaml (see config.example.yaml)" >&2
  exit 1
fi

exec python3 "$SCRIPT_DIR/fdroid_metadata.py" \
  --store "$STORE" --repo "$REPO_DIR" --author "$AUTHOR" "$@"
