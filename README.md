# Headless Android emulator (for adb-driven app testing)

A throwaway Android 14 emulator I can drive over `adb` to install and tap-test the
`sfit` app without depending on a flaky wireless link to your phone. Headless (no
GUI) — I install the APK, launch, screenshot, and tap via `adb`.

## Prerequisite: KVM (one-time BIOS change)

This box (i5-6500) supports VT-x but it's **disabled in BIOS**, so `/dev/kvm` doesn't
exist and `docker compose up` will fail on the `devices:` mapping. That's intentional —
an x86 emulator without KVM is unusably slow.

1. Reboot → BIOS/UEFI → enable **Intel Virtualization Technology (VT-x)** → save.
2. Verify: `grep -c vmx /proc/cpuinfo` (should be > 0), then `ls -l /dev/kvm`.
3. If `/dev/kvm` is root:kvm 0660, ensure the Docker daemon/user can use it
   (running the container as root, which this does, is sufficient).

## Run

```bash
cd /data/android
docker compose up -d --build      # first run downloads ~2-3 GB into /data/storage/android
docker compose logs -f android    # watch the SDK bootstrap + boot
```

First boot: SDK + system image download to `/data/storage/android/sdk`, the AVD is
created under `/data/storage/android/avd`, then the emulator boots. Nothing large
touches the system disk.

## Wait for boot, then drive it

```bash
docker exec android-emulator adb wait-for-device
docker exec android-emulator adb shell getprop sys.boot_completed   # "1" = ready
```

## Install & test the app

```bash
docker cp ~/git/personal/sfit/app/build/outputs/apk/debug/app-debug.apk android-emulator:/tmp/
docker exec android-emulator adb install -r /tmp/app-debug.apk
docker exec android-emulator adb shell monkey -p net.bam.sfit -c android.intent.category.LAUNCHER 1
docker exec android-emulator adb exec-out screencap -p > /tmp/screen.png
```

## Storage layout

| Path | What | Where |
|---|---|---|
| `/data/storage/android/sdk` | cmdline-tools, platform-tools, emulator, system images | 15 TB array |
| `/data/storage/android/avd` | AVD config + qcow2 disks | 15 TB array |
| Docker image | JDK + emulator libs only (small) | system disk |

## Notes / knobs (docker-compose.yml `environment:`)

- `ANDROID_API` / `ANDROID_TAG` / `ANDROID_ABI` — image selection (default Android 14,
  `google_apis`, `x86_64`).
- `EMU_MEMORY` — guest RAM in MB (default 2048; this box has ~3.6 GB free, so don't
  raise it much).
- `ACCEL=off` + commenting the `devices:` block — forces a software-mode trial without
  KVM (slow; only for a quick smoke test).
- `entrypoint.sh` passes `-wipe-data` each boot for a clean device; remove it to
  persist state across restarts.
