#!/usr/bin/env bash
# Build an Android app in a DISPOSABLE container from the baked android-builder image.
#
# This is the "compile" front door that lives in /data/android alongside the emulator.
# Any app project on this box builds the same way, without installing a JDK/SDK/Gradle
# toolchain on the host: point this at the project dir and it spins a throwaway
# container, runs Gradle inside it, and drops the APK back in the project's build/ tree.
#
# Usage:
#   ./build.sh <project-dir> [gradle-task ...]
#   ./build.sh /path/to/project                    # default: :app:assembleDebug
#   ./build.sh /path/to/project :app:assembleRelease
#
# Successful APK-producing builds are published into the in-repo BAM Store at
# `store/` (override with `directories.bam-store` in config.yaml). Set
# BAM_STORE_PUBLISH=0 to build only, BAM_STORE_CHANGELOG="..." for the changelog.
# The full list of build/publish env knobs lives in README.md
# ("Environment knobs (build + publish)") — that table is authoritative.
#
# The mount contract (see Dockerfile.builder):
#   <project-parent>         -> /workspace     (source in, APK out)
#   <project-dir>/.gradle-cache -> /gradle-cache (this project's OWN persistent cache)
# The SDK is baked into the image, private per container — nothing shared, no collisions.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${BUILDER_IMAGE:-android-builder:local}"
BAM_STORE_PUBLISH="${BAM_STORE_PUBLISH:-1}"
BAM_STORE_CHANGELOG="${BAM_STORE_CHANGELOG:-Built by /data/android/build.sh}"
FDROID_PUBLISH="${FDROID_PUBLISH:-1}"

PROJECT="${1:-}"
if [ -z "$PROJECT" ]; then
  echo "usage: $0 <project-dir> [gradle-task ...]" >&2
  exit 2
fi
shift || true
PROJECT="$(cd "$PROJECT" && pwd)"   # normalize to absolute
PROJECT_PARENT="$(cd "$PROJECT/.." && pwd)"
PROJECT_NAME="$(basename "$PROJECT")"
WORKDIR="/workspace/$PROJECT_NAME"

if [ ! -x "$PROJECT/gradlew" ]; then
  echo "!! no ./gradlew in $PROJECT — is that the Android project root?" >&2
  exit 1
fi

# Default task if none given.
if [ "$#" -eq 0 ]; then
  set -- :app:assembleDebug
fi

# Per-project Gradle cache lives alongside the project (git-ignore it there).
CACHE="$PROJECT/.gradle-cache"
mkdir -p "$CACHE"
STAMP="$(mktemp)"
trap 'rm -f "$STAMP"' EXIT
touch "$STAMP"

echo ">> Building $PROJECT  [tasks: $*]"
echo ">> image=$IMAGE  cache=$CACHE"
echo ">> mount=$PROJECT_PARENT:/workspace  workdir=$WORKDIR"

docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/gradle-cache \
  -v "$PROJECT_PARENT":/workspace \
  -v "$CACHE":/gradle-cache \
  -w "$WORKDIR" \
  "$IMAGE" \
  ./gradlew --no-daemon "$@"

# APKs this build actually (re)wrote — the normal case.
mapfile -t APKS < <(
  find "$PROJECT" -path '*/build/outputs/apk/*.apk' -newer "$STAMP" -type f -printf '%p\n' 2>/dev/null | sort
)
# Up-to-date build: Gradle rewrote nothing, so nothing is newer than the stamp. Fall back to
# the APKs already on disk so the BAM Store still gets (re)published without a clean rebuild.
# Publishing is idempotent — the store keys each release by the APK's versionCode and
# overwrites that slot, so republishing an unchanged build just re-writes the same entry.
if [ "${#APKS[@]}" -eq 0 ]; then
  mapfile -t APKS < <(
    find "$PROJECT" -path '*/build/outputs/apk/*.apk' -type f -printf '%p\n' 2>/dev/null | sort
  )
fi

echo ">> Done. APK(s):"
if [ "${#APKS[@]}" -eq 0 ]; then
  echo "   (none found from this build)"
  exit 0
fi
printf '   %s\n' "${APKS[@]}"

if [ "$BAM_STORE_PUBLISH" = "0" ]; then
  echo ">> BAM Store publish skipped (BAM_STORE_PUBLISH=0)."
  exit 0
fi

# The store lives in this repo at store/; directories.bam-store is only an
# optional override for an out-of-tree checkout.
STORE="$("$SCRIPT_DIR/config.sh" get directories bam-store || true)"
STORE="${STORE:-$SCRIPT_DIR/store}"
if [ ! -x "$STORE/tools/publish" ]; then
  echo "!! BAM Store publish requested, but no publisher at $STORE/tools/publish" >&2
  exit 1
fi

# The APK binaries live on the big disk, not beside the tools — see
# directories.bam-store-apks in config.yaml.
BAM_STORE_APKS="${BAM_STORE_APKS:-$("$SCRIPT_DIR/config.sh" get directories bam-store-apks || true)}"
export BAM_STORE_APKS

echo ">> Publishing APK(s) to BAM Store: $STORE (payload: ${BAM_STORE_APKS:-in-repo})"
for apk in "${APKS[@]}"; do
  "$STORE/tools/publish" "$apk" --changelog "$BAM_STORE_CHANGELOG"
done

# Second index: mirror the freshly published APKs into the F-Droid repo so both
# the custom index.json and the signed F-Droid index stay in sync during the
# transition. Non-fatal — a build must not fail because the repo isn't set up.
if [ "$FDROID_PUBLISH" = "0" ]; then
  echo ">> F-Droid publish skipped (FDROID_PUBLISH=0)."
  exit 0
fi
echo ">> Updating the F-Droid repo"
if ! "$SCRIPT_DIR/scripts/fdroid-publish.sh"; then
  echo "!! F-Droid repo update failed — the BAM Store publish above still succeeded." >&2
fi
