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
# The mount contract (see Dockerfile.builder):
#   <project-parent>         -> /workspace     (source in, APK out)
#   <project-dir>/.gradle-cache -> /gradle-cache (this project's OWN persistent cache)
# The SDK is baked into the image, private per container — nothing shared, no collisions.
set -euo pipefail

IMAGE="${BUILDER_IMAGE:-android-builder:local}"

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

echo ">> Done. APK(s):"
find "$PROJECT" -path '*/build/outputs/apk/*.apk' -newer "$CACHE" -printf '   %p\n' 2>/dev/null || true
