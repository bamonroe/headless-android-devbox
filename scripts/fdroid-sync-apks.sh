#!/usr/bin/env bash
# Copy the BAM Store's APK binaries into the F-Droid repo's repo/ directory.
#
# The store keeps its binaries at directories.bam-store-apks as
# <package>-<versionCode>.apk; fdroidserver wants them under
# <fdroid-repo>/repo/ and derives everything else by scanning them. This is a
# one-way sync (store -> fdroid) and is safe to re-run: unchanged files are
# skipped and nothing in the store is modified.
#
# androidTest APKs (<package>.test-*.apk) are never published — they are test
# harnesses, not apps.
#
# Usage: scripts/fdroid-sync-apks.sh
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../config.sh
source "$ROOT/config.sh"

REPO_DIR="${FDROID_REPO:-$(cfg_get directories fdroid-repo || true)}"
APK_DIR="${BAM_STORE_APKS:-$(cfg_get directories bam-store-apks || true)}"

if [ -z "$REPO_DIR" ] || [ -z "$APK_DIR" ]; then
  echo "!! directories.fdroid-repo and directories.bam-store-apks must be set in config.yaml" >&2
  exit 1
fi
if [ ! -d "$APK_DIR" ]; then
  echo "!! no such APK directory: $APK_DIR" >&2
  exit 1
fi

DEST="$REPO_DIR/repo"
mkdir -p "$DEST"

copied=0 skipped=0 tests=0
shopt -s nullglob
for apk in "$APK_DIR"/*.apk; do
  base="$(basename "$apk")"
  case "$base" in
    *.test-*.apk) tests=$((tests + 1)); continue ;;
  esac
  if [ -f "$DEST/$base" ] && cmp -s "$apk" "$DEST/$base"; then
    skipped=$((skipped + 1))
    continue
  fi
  cp -p "$apk" "$DEST/$base"
  copied=$((copied + 1))
done

echo "synced $DEST: $copied copied, $skipped unchanged, $tests androidTest APKs skipped"
echo "next: scripts/fdroid.sh update -c"
