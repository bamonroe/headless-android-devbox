#!/usr/bin/env bash
# Finish retiring the old /data/bam-store checkout.
#
# The APK payload already lives at /data/android/store/repo (hardlinked back into
# the old checkout so serving keeps working). The only remaining steps need root:
# repoint Caddy at the merged store, reload it, verify, then retire the checkout.
#
# Run as root:  sudo /data/android/scripts/retire-bam-store.sh
set -euo pipefail

CADDYFILE=/etc/caddy/Caddyfile
OLD=/data/bam-store
NEW=/data/android/store

[[ $EUID -eq 0 ]] || { echo "error: run this as root (sudo)" >&2; exit 1; }
[[ -d $NEW/repo/apks ]] || { echo "error: $NEW/repo/apks missing" >&2; exit 1; }

echo "==> backing up $CADDYFILE"
cp -a "$CADDYFILE" "$CADDYFILE.bak-retire-bam-store"

echo "==> repointing apps.bam root at $NEW/repo"
sed -i "s#root \* $OLD/repo#root * $NEW/repo#" "$CADDYFILE"
grep -n -A3 'apps.bam' "$CADDYFILE"

echo "==> validating and reloading caddy"
caddy validate --config "$CADDYFILE" --adapter caddyfile
systemctl reload caddy

echo "==> verifying"
apk=$(ls "$NEW"/repo/apks/*.apk | head -1)
for url in "http://apps.bam/index.json" "http://apps.bam/apks/$(basename "$apk")"; do
	code=$(curl -s -o /dev/null -w '%{http_code}' "$url")
	echo "$code  $url"
	[[ $code == 200 ]] || { echo "error: expected 200; leaving $OLD in place" >&2; exit 1; }
done

echo "==> retiring $OLD"
mv "$OLD" "$OLD.retired"

echo "Done. Serving from $NEW/repo. Delete $OLD.retired after one clean"
echo "publish cycle from the new home (./build.sh <project>)."
