#!/usr/bin/env bash
# Drive the headless Dockerized Android emulator at /data/android.
#
# The emulator's adb server lives INSIDE the container, so every device command
# goes through `docker exec android-emulator adb ...` (wrapped here as `eadb`).
# The host's /usr/bin/adb cannot see this emulator — that's for the phone.
#
#   emulator.sh status                 # container up? booted? which Android?
#   emulator.sh up                     # docker compose up -d, then wait for boot
#   emulator.sh boot-wait              # block until sys.boot_completed=1
#   emulator.sh down                   # docker compose down
#   emulator.sh install <apk>          # docker cp + adb install -r
#   emulator.sh launch <package>       # start the launcher activity
#   emulator.sh screenshot [file]      # PNG (default /tmp/emu-screen.png) -> prints path
#   emulator.sh ui                     # uiautomator XML dump (real tap coords)
#   emulator.sh logcat [args...]       # passthrough
#   emulator.sh shell  [cmd...]        # passthrough
#   emulator.sh adb    [args...]       # raw adb passthrough
#
# Notes: Android 14 headless, KVM-accelerated. entrypoint boots with -wipe-data,
# so app state (incl. any configured server URL/key) resets each container start.
# The emulator has NO real camera / ARCore / RAW — UI, lifecycle, and permission
# testing only. Camera/ARCore/RAW/SharedCamera work must go to the Pixel 8a.
set -euo pipefail
C="${EMU_CONTAINER:-android-emulator}"
COMPOSE_DIR="${EMU_DIR:-/data/android}"
eadb() { docker exec "$C" adb "$@"; }
running() { docker ps --format '{{.Names}}' | grep -qx "$C"; }

cmd="${1:-status}"; shift || true
case "$cmd" in
    status)
        if running; then
            b=$(eadb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
            echo "container: up ($C)"
            echo "booted:    ${b:-0}   (1 = ready)"
            echo "android:   $(eadb shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"
            eadb devices | tail -n +2 | sed '/^[[:space:]]*$/d'
        else
            echo "container: DOWN — start with:  $0 up"
        fi ;;
    up)
        ( cd "$COMPOSE_DIR" && docker compose up -d )
        "$0" boot-wait ;;
    boot-wait)
        echo ">> waiting for device + full boot ..."
        eadb wait-for-device
        until [ "$(eadb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do sleep 2; done
        echo ">> emulator booted." ;;
    down)
        ( cd "$COMPOSE_DIR" && docker compose down ) ;;
    install)
        apk="${1:?usage: $0 install <apk>}"
        [ -f "$apk" ] || { echo "no such apk: $apk" >&2; exit 1; }
        docker cp "$apk" "$C:/tmp/app.apk"
        eadb install -r /tmp/app.apk ;;
    launch)
        pkg="${1:?usage: $0 launch <package>}"
        eadb shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1 ;;
    screenshot)
        out="${1:-/tmp/emu-screen.png}"
        eadb exec-out screencap -p > "$out"
        echo "$out" ;;
    ui)      eadb exec-out uiautomator dump /dev/tty ;;
    logcat)  eadb logcat "$@" ;;
    shell)   eadb shell "$@" ;;
    adb)     eadb "$@" ;;
    *) echo "usage: $0 {status|up|boot-wait|down|install <apk>|launch <pkg>|screenshot [file]|ui|logcat|shell|adb}"; exit 1 ;;
esac
