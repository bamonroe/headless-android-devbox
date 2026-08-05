#!/usr/bin/env bash
# Run an fdroidserver command in a disposable container against this box's repo dir.
#
# The front door for everything F-Droid here — nothing load-bearing should live in
# shell history. Paths come from config.yaml (the single source of truth):
#   directories.fdroid-repo      -> mounted at /repo   (config.yml, repo/, metadata/)
#   directories.fdroid-keystore  -> mounted at /keystore (read-only)
#
# Usage:
#   scripts/fdroid.sh init                 # first-time repo setup
#   scripts/fdroid.sh update -c            # rescan APKs + regenerate/sign the index
#   scripts/fdroid.sh deploy               # push the repo to its serving location
#   scripts/fdroid.sh shell                # interactive poke-around in the container
#
# It always runs as the invoking uid:gid so generated files stay owned by you.
# Image: fdroid:local (override with FDROID_IMAGE); build it with
#   docker build -f Dockerfile.fdroid -t fdroid:local .
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
KEYSTORE="${FDROID_KEYSTORE:-$(cfg_get directories fdroid-keystore || true)}"

if [ -z "$REPO_DIR" ]; then
  echo "!! directories.fdroid-repo is not set in config.yaml (see config.example.yaml)" >&2
  exit 1
fi
mkdir -p "$REPO_DIR"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "!! no $IMAGE image — build it first:" >&2
  echo "     docker build -f $ROOT/Dockerfile.builder -t android-builder:local $ROOT" >&2
  echo "     docker build -f $ROOT/Dockerfile.fdroid  -t $IMAGE $ROOT" >&2
  exit 1
fi

MOUNTS=(-v "$REPO_DIR:/repo")
if [ -n "$KEYSTORE" ] && [ -f "$KEYSTORE" ]; then
  MOUNTS+=(-v "$KEYSTORE:/keystore:ro")
fi

# `shell` drops you into the container instead of running fdroid.
if [ "${1:-}" = "shell" ]; then
  shift || true
  exec docker run --rm -it --user "$(id -u):$(id -g)" \
    "${MOUNTS[@]}" -w /repo "$IMAGE" bash "$@"
fi

if [ "$#" -eq 0 ]; then
  set -- --help
fi

exec docker run --rm -i --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  "${MOUNTS[@]}" -w /repo "$IMAGE" fdroid "$@"
