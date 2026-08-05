#!/usr/bin/env bash
# Create the F-Droid repo signing keystore — once, and never again.
#
# The repo index is signed with this key. If it is lost, every client that added
# the repo has to remove and re-add it, so: it lives OFF git on the big disk and
# it is your job to back it up.
#
# Paths + identity come from config.yaml (the single source of truth):
#   directories.fdroid-keystore  -> the PKCS#12 file this creates
#   fdroid.keystore-alias        -> the key alias inside it
#
# A random 32-char password is generated and written next to the keystore as
# <keystore>.pass (mode 0600). `fdroid init`/`update` read it from there.
#
# Usage:
#   scripts/fdroid-keystore.sh          # create it (refuses if one already exists)
#   scripts/fdroid-keystore.sh --show   # print the path, alias and fingerprint
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE="${FDROID_IMAGE:-fdroid:local}"

# shellcheck source=../config.sh
source "$ROOT/config.sh"

KEYSTORE="${FDROID_KEYSTORE:-$(cfg_get directories fdroid-keystore || true)}"
ALIAS="${FDROID_KEY_ALIAS:-$(cfg_get fdroid keystore-alias || true)}"
DNAME="${FDROID_KEY_DNAME:-CN=$(cfg_get fdroid name || echo "F-Droid Repo"), OU=fdroid}"

if [ -z "$KEYSTORE" ]; then
  echo "!! directories.fdroid-keystore is not set in config.yaml (see config.example.yaml)" >&2
  exit 1
fi
if [ -z "$ALIAS" ]; then
  echo "!! fdroid.keystore-alias is not set in config.yaml (see config.example.yaml)" >&2
  exit 1
fi

PASSFILE="$KEYSTORE.pass"
KEYDIR="$(dirname "$KEYSTORE")"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "!! no $IMAGE image — build it first:" >&2
  echo "     docker build -f $ROOT/Dockerfile.fdroid -t $IMAGE $ROOT" >&2
  exit 1
fi

# keytool isn't on the image's PATH — call it by absolute path inside the JDK.
KEYTOOL="${FDROID_KEYTOOL:-/opt/java/openjdk/bin/keytool}"

run_keytool() {
  docker run --rm -i --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -v "$KEYDIR:/keys" -w /keys "$IMAGE" \
    "$KEYTOOL" "$@"
}

if [ "${1:-}" = "--show" ]; then
  if [ ! -f "$KEYSTORE" ]; then
    echo "no keystore at $KEYSTORE — run scripts/fdroid-keystore.sh to create it" >&2
    exit 1
  fi
  echo "keystore: $KEYSTORE"
  echo "alias:    $ALIAS"
  run_keytool -list -v -keystore "$(basename "$KEYSTORE")" -alias "$ALIAS" \
    -storetype PKCS12 -storepass "$(cat "$PASSFILE")" | grep -E 'SHA256:|Valid from'
  exit 0
fi

if [ -f "$KEYSTORE" ]; then
  echo "!! a keystore already exists at $KEYSTORE — refusing to overwrite it." >&2
  echo "   Signing with a different key breaks every client that added this repo." >&2
  echo "   Inspect it with: scripts/fdroid-keystore.sh --show" >&2
  exit 1
fi

mkdir -p "$KEYDIR"
chmod 700 "$KEYDIR"

# 24 random bytes -> base64 -> strip non-alphanumerics; ~32 chars, no SIGPIPE.
PASS="$(head -c 24 /dev/urandom | base64 | LC_ALL=C tr -dc 'A-Za-z0-9')"
umask 077
printf '%s\n' "$PASS" >"$PASSFILE"
chmod 600 "$PASSFILE"

run_keytool -genkeypair \
  -keystore "$(basename "$KEYSTORE")" -storetype PKCS12 \
  -alias "$ALIAS" -keyalg RSA -keysize 4096 -validity 10000 \
  -dname "$DNAME" -storepass "$PASS" -keypass "$PASS"

chmod 600 "$KEYSTORE"

cat <<EOF

Created the F-Droid repo signing keystore.

  keystore:  $KEYSTORE
  password:  $PASSFILE   (mode 0600 — 'fdroid init' reads it from here)
  alias:     $ALIAS

BACK BOTH FILES UP somewhere off this box. Losing them means every client that
added the repo must remove and re-add it. Neither is in git, and neither should
ever be.
EOF
