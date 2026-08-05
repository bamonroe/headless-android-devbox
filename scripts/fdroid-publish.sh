#!/usr/bin/env bash
# Push the current BAM Store contents into the F-Droid repo and re-sign its index.
#
# The one command that takes the store from "an APK was just published" to "the
# F-Droid repo serves it": sync the binaries, project the metadata, then let
# fdroidserver rescan and sign. Each step is its own script; this only sequences
# them, so the pieces stay independently runnable.
#
#   scripts/fdroid-sync-apks.sh   store APKs      -> <repo>/repo/
#   scripts/fdroid-metadata.sh    store index.json-> <repo>/metadata/
#   scripts/fdroid.sh update -c   rescan + regenerate + sign the index
#
# Called automatically by build.sh after a successful publish; set
# FDROID_PUBLISH=0 to skip that (the custom index.json store is unaffected).
# Both indexes are kept in sync during the transition off index.json.
#
# Usage: scripts/fdroid-publish.sh
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="${FDROID_IMAGE:-fdroid:local}"

# shellcheck source=../config.sh
source "$ROOT/config.sh"

REPO_DIR="${FDROID_REPO:-$(cfg_get directories fdroid-repo || true)}"
if [ -z "$REPO_DIR" ] || [ ! -f "$REPO_DIR/config.yml" ]; then
  echo "!! no initialized F-Droid repo (directories.fdroid-repo + config.yml)." >&2
  echo "   set it up once: scripts/fdroid.sh init && scripts/fdroid-config.sh" >&2
  exit 1
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "!! no $IMAGE image — build it: docker build -f $ROOT/Dockerfile.fdroid -t $IMAGE $ROOT" >&2
  exit 1
fi

"$SCRIPT_DIR/fdroid-sync-apks.sh"
"$SCRIPT_DIR/fdroid-metadata.sh"
"$SCRIPT_DIR/fdroid.sh" update -c

echo ">> F-Droid repo updated: $REPO_DIR/repo (index signed)"
