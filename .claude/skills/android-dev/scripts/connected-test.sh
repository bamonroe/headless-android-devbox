#!/usr/bin/env bash
# Run an Android instrumented (androidTest) suite against the in-container emulator.
#
# WHY THIS EXISTS — the "two isolated adb worlds" problem (see ../../../CLAUDE.md):
# Gradle's own `connectedDebugAndroidTest` starts an adb server INSIDE the throwaway
# build container. That adb lives in a different world than the emulator's in-container
# adb, so it finds nothing and the task dies with "No connected devices!". Bridging the
# two over TCP doesn't reliably help either — AGP's device discovery (ddmlib) assumes the
# adb server is on localhost, so it can't just be pointed at the emulator container.
#
# The reliable fix is to keep each half in the world where it already works: BUILD the
# app + androidTest APKs in the builder container, then INSTALL and RUN the instrumentation
# through the emulator container's OWN adb — the one adb that can actually see the emulator.
# That's exactly what this script does, as one command.
#
# Usage:
#   connected-test.sh <project-dir> [extra `am instrument` args...]
#
#   connected-test.sh /home/bam/git/personal/xopp_android
#   connected-test.sh <proj> -e class com.xopp.android.SmokeTest        # one class
#   connected-test.sh <proj> -e size small                              # a test-size filter
#
# Exit status IS the test result: 0 only if every test passed; non-zero if any test
# fails/errors or the runner can't start.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMU="$HERE/emulator.sh"
# scripts -> android-dev -> skills -> .claude -> /data/android
TOOLCHAIN="$(cd "$HERE/../../../.." && pwd)"
IMAGE="${BUILDER_IMAGE:-android-builder:local}"

PROJECT="${1:?usage: $0 <project-dir> [extra am instrument args...]}"; shift || true
PROJECT="$(cd "$PROJECT" && pwd)"
PROJECT_PARENT="$(cd "$PROJECT/.." && pwd)"

# 1) Build both APKs in the disposable builder (the compile world).
echo ">> [1/5] building debug + androidTest APKs ..."
"$TOOLCHAIN/build.sh" "$PROJECT" :app:assembleDebug :app:assembleDebugAndroidTest

# 2) Locate the freshly built APKs.
APP_APK="$(find "$PROJECT" -path '*/outputs/apk/debug/*.apk' ! -path '*androidTest*' -print 2>/dev/null | head -1)"
TEST_APK="$(find "$PROJECT" -path '*/outputs/apk/androidTest/debug/*.apk' -print 2>/dev/null | head -1)"
[ -n "$APP_APK"  ] || { echo "!! no debug APK under $PROJECT" >&2; exit 1; }
[ -n "$TEST_APK" ] || { echo "!! no androidTest APK — does the project have src/androidTest?" >&2; exit 1; }
echo ">> app:  $APP_APK"
echo ">> test: $TEST_APK"

# 3) Read the instrumentation component (<testPackage>/<runner>) straight from the test
#    APK's manifest via aapt in the builder image — authoritative and independent of
#    whatever else happens to be installed on the emulator. The package comes from
#    `badging`; the runner from the manifest's <instrumentation> node (badging alone
#    doesn't surface it for AGP test APKs). The APK path is passed by env so the inner
#    script needs no host interpolation; the output is parsed here on the host.
echo ">> [2/5] reading instrumentation component from the test APK ..."
REL_TEST="/workspace/${TEST_APK#"$PROJECT_PARENT"/}"
RAW="$(docker run --rm --user "$(id -u):$(id -g)" -e APK="$REL_TEST" \
  -v "$PROJECT_PARENT":/workspace -w /workspace "$IMAGE" \
  bash -lc 'aapt=$(ls "$ANDROID_SDK_ROOT"/build-tools/*/aapt 2>/dev/null | sort -V | tail -1);
            "$aapt" dump badging "$APK" 2>/dev/null;
            "$aapt" dump xmltree "$APK" AndroidManifest.xml 2>/dev/null')"
TEST_PKG="$(printf '%s\n' "$RAW" | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -1)"
RUNNER="$(printf '%s\n' "$RAW" | awk '/E: instrumentation/{f=1; next} f && /android:name\(/ {sub(/.*android:name\([^)]*\)="/, ""); sub(/".*/, ""); print; exit}')"
[ -n "$TEST_PKG" ] || { echo "!! could not read test package from $TEST_APK" >&2; exit 1; }
[ -n "$RUNNER"   ] || { echo "!! no <instrumentation> runner in $TEST_APK (missing test runner dep?)" >&2; exit 1; }
COMPONENT="$TEST_PKG/$RUNNER"
echo ">> instrumentation: $COMPONENT"

# 4) Ensure the emulator is up, then install both APKs through ITS adb.
echo ">> [3/5] ensuring emulator is booted ..."
"$EMU" boot-wait >/dev/null
echo ">> [4/5] installing app + test APKs on the emulator ..."
"$EMU" install "$APP_APK"  >/dev/null
"$EMU" install "$TEST_APK" >/dev/null

# 5) Run the instrumentation and turn its output into a real exit code.
echo ">> [5/5] running $COMPONENT ..."
OUT="$("$EMU" shell am instrument -w -r "$@" "$COMPONENT" 2>&1)"
printf '%s\n' "$OUT"

if printf '%s\n' "$OUT" | grep -qE 'FAILURES!!!|INSTRUMENTATION_FAILED|INSTRUMENTATION_RESULT: shortMsg'; then
    echo ">> RESULT: FAILED" >&2
    exit 1
fi
if printf '%s\n' "$OUT" | grep -qE '^OK \([0-9]+ test'; then
    echo ">> RESULT: PASSED"
    exit 0
fi
# No pass summary and no explicit failure marker → the runner never completed cleanly.
echo ">> RESULT: no test summary — the instrumentation did not run to completion." >&2
exit 1
