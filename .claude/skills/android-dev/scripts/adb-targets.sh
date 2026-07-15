#!/usr/bin/env bash
# Enumerate every Android target across the TWO separate adb worlds on this box:
#
#   - host adb (/usr/bin/adb)          -> physical phone (Pixel 8a, usually tailnet)
#   - container adb (android-emulator) -> the headless Dockerized emulator
#
# These are ISOLATED: the host adb server does not see the emulator, and the
# emulator's in-container adb does not see the phone. Pick the right world per target.
set -uo pipefail
HOST_ADB="${HOST_ADB:-/usr/bin/adb}"
C="${EMU_CONTAINER:-android-emulator}"

row() { printf "  %-24s %-9s %-14s %s\n" "$1" "$2" "${3:-?}" "${4:-}"; }

echo "== PHYSICAL  (host: $HOST_ADB) =="
if command -v "$HOST_ADB" >/dev/null 2>&1; then
    mapfile -t lines < <("$HOST_ADB" devices -l 2>/dev/null | tail -n +2 | sed '/^[[:space:]]*$/d')
    if [ "${#lines[@]}" -eq 0 ]; then
        echo "  (none) — enable wireless debugging then 'adb connect <ip>:5555',"
        echo "          or plug in a DATA usb cable (charge-only won't enumerate)."
    else
        for l in "${lines[@]}"; do
            s=$(awk '{print $1}' <<<"$l"); st=$(awk '{print $2}' <<<"$l")
            m=$(grep -o 'model:[^ ]*' <<<"$l" | cut -d: -f2)
            [[ "$s" == *:* ]] && net="(wireless/tcp)" || net=""
            row "$s" "$st" "$m" "$net"
        done
    fi
else
    echo "  host adb not found at $HOST_ADB"
fi

echo "== EMULATOR  (docker exec $C adb) =="
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$C"; then
    b=$(docker exec "$C" adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')
    rel=$(docker exec "$C" adb shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
    mapfile -t elines < <(docker exec "$C" adb devices 2>/dev/null | tail -n +2 | sed '/^[[:space:]]*$/d')
    if [ "${#elines[@]}" -eq 0 ]; then
        row "(booting?)" "-" "Android $rel" "boot_completed=${b:-0}"
    else
        for l in "${elines[@]}"; do
            row "$(awk '{print $1}' <<<"$l")" "$(awk '{print $2}' <<<"$l")" "Android $rel" "boot_completed=${b:-0}"
        done
    fi
else
    echo "  container '$C' not running — start it:  emulator.sh up"
fi
