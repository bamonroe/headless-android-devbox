# Headless Android emulator + disposable APK builder (adb-driven)

A throwaway Android 14 emulator you drive over `adb` to install and tap-test apps
headlessly (no GUI), plus a disposable container that **builds** the APKs. Together
this directory is one front door for both building and running Android apps without
installing a JDK/SDK/Gradle toolchain on the host.

Machine-specific values (storage location, physical-device IPs) are **not** hardcoded
— they live in `config.yaml`, which is git-ignored. Copy the template first:

```bash
cp config.example.yaml config.yaml   # then edit: your storage dir, device IPs
```

`config.sh` reads it (`./config.sh get directories storage`), and the tooling pulls
from it, so this repo is safe to clone/publish and still works on your box.

## Prerequisite: KVM (one-time BIOS change)

An x86 emulator without KVM is unusably slow, so `/dev/kvm` must exist — it only does
when Intel VT-x is enabled in BIOS. If `docker compose up` fails on the `devices:`
mapping, VT-x is off.

1. Reboot → BIOS/UEFI → enable **Intel Virtualization Technology (VT-x)** → save.
2. Verify: `grep -c vmx /proc/cpuinfo` (> 0), then `ls -l /dev/kvm`.
3. Running the container as root (this does) is sufficient to use `/dev/kvm`.

## Run the emulator

```bash
S=.claude/skills/android-dev/scripts/emulator.sh
"$S" up          # docker compose up -d (config-driven storage) + wait for boot
"$S" status      # up? booted? which Android?
```

First boot downloads the SDK + system image into `<storage>/android/sdk` and creates
the AVD under `<storage>/android/avd` (`<storage>` from `config.yaml`); nothing large
touches the system disk. The raw equivalent is `docker compose up -d --build` after
exporting `STORAGE_DIR` (see `config.sh export-env`).

## Build an APK (disposable container)

```bash
./build.sh <project-dir> [gradle-task]     # default :app:assembleDebug
```

One baked `android-builder:local` image (JDK 21 + SDK), a throwaway container per
build, and a per-project Gradle cache at `<project>/.gradle-cache`. See CLAUDE.md.

## Install & test the app on the emulator

```bash
S=.claude/skills/android-dev/scripts/emulator.sh
"$S" install /path/to/app-debug.apk
"$S" launch <package>
"$S" screenshot /tmp/screen.png
"$S" ui                                     # uiautomator dump → real tap bounds
```

## Storage layout

| Path | What |
|---|---|
| `<storage>/android/sdk` | cmdline-tools, platform-tools, emulator, system images |
| `<storage>/android/avd` | AVD config + qcow2 disks |
| Docker image | JDK + emulator libs only (small; on the system disk) |

`<storage>` is `directories.storage` in `config.yaml` (a big disk, not the system disk).

## Notes / knobs (docker-compose.yml `environment:`)

- `ANDROID_API` / `ANDROID_TAG` / `ANDROID_ABI` — image selection (default Android 14,
  `google_apis`, `x86_64`).
- `EMU_MEMORY` — guest RAM in MB (default 2048).
- `ACCEL=off` + commenting the `devices:` block — software-mode trial without KVM (slow).
- `entrypoint.sh` passes `-wipe-data` each boot for a clean device; remove it to persist
  state across restarts.
