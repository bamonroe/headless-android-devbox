# /data/android — headless Android emulator for APK development

Purpose: a throwaway, headless Android 14 emulator driven entirely over `adb` inside a
Docker container. It's the fast/disposable target for building and tap-testing the APKs
built on this box (UI, layout, navigation, lifecycle, permission flows) before a finished
build is published to the **BAM Store** and/or installed on the physical Pixel 8a.

This directory is only the emulator scaffold (`Dockerfile`, `entrypoint.sh`,
`docker-compose.yml`, `README.md`). The **day-to-day workflow lives in the `android-dev`
skill** (`~/.claude/skills/android-dev`) — its `scripts/emulator.sh` and
`scripts/adb-targets.sh` wrap everything below. Reach for the skill first; this file is
the reference for what the skill is driving and how to change it.

## The two isolated adb worlds (read this first)

There are two separate adb worlds on this box and they do **not** see each other:

| Target | adb path | Serial | Reach it with |
|---|---|---|---|
| **Emulator** (this dir) | in-container | `emulator-5554` | `docker exec android-emulator adb …` |
| **Physical Pixel 8a** ("akita") | host `/usr/bin/adb` | `100.64.0.3:5555` (tailnet) | `adb -s <serial> …` |
| **Physical Tab S6 Lite** ("stab", SM-P620) | host `/usr/bin/adb` | `100.64.0.5:5555` (tailnet) | `adb -s <serial> …` |

The host's `/usr/bin/adb` cannot see this emulator; the emulator's in-container adb cannot
see the phone. `scripts/adb-targets.sh` (in the skill) lists both at once. Use the
emulator for UI/logic iteration; use the phone for anything touching real hardware
(camera, ARCore, RAW/DNG, SharedCamera, sensors) — the emulator has none of those.

## KVM (the one hard prerequisite — now satisfied)

An x86 emulator is unusably slow without KVM. `/dev/kvm` exists only when Intel VT-x is
enabled in BIOS; it is, and the emulator boots KVM-accelerated in ~30-60s. The
`docker-compose.yml` `devices:` mapping passes `/dev/kvm` into the container, so `up`
fails fast if it ever disappears — that's the correct signal, not a bug.

If `docker compose up` fails on the `devices:` mapping, KVM is missing again:

```bash
grep -c vmx /proc/cpuinfo      # 0 = VT-x got turned off in BIOS; re-enable it there
ls -l /dev/kvm                 # missing but vmx>0 → sudo modprobe kvm_intel
```

VT-x is a firmware toggle (Advanced → CPU Configuration → *Intel Virtualization
Technology*), not a kernel/module problem — the modules are present and match the kernel.

## Bring up, boot, drive

The skill's `emulator.sh` is the fast path; the raw equivalents:

```bash
cd /data/android && docker compose up -d --build   # first run downloads ~2-3 GB (below)
docker exec android-emulator adb wait-for-device
docker exec android-emulator adb shell getprop sys.boot_completed   # "1" = ready
```

```bash
# via the skill instead:
~/.claude/skills/android-dev/scripts/emulator.sh up          # up + wait for boot
~/.claude/skills/android-dev/scripts/emulator.sh status      # up? booted? which Android?
```

First run downloads cmdline-tools + platform-tools + emulator + the Android 14 x86_64
system image into `/data/storage/android/sdk`, creates the AVD under
`/data/storage/android/avd`, then boots. All large files stay on the 15 TB array; the
Docker image itself is small. Later runs skip straight to boot.

## Building APKs — the disposable build container (preferred)

This directory is the single front door for **building** Android APKs too, not just
running them. Rather than installing a JDK/SDK/Gradle toolchain on the host per project,
builds run in a **throwaway container** from a reusable image with the SDK baked in:

```bash
cd /data/android
./build.sh ~/git/personal/sfit                        # default :app:assembleDebug
./build.sh ~/git/personal/trashbot/android :app:assembleRelease
```

- **Image** (`Dockerfile.builder`, tag `android-builder:local`) — JDK 21 (matches the
  global pin) + Android SDK platforms 34 & 35 + build-tools, all baked in and **private to
  each container**, so parallel builds never collide over a shared SDK. Rebuild it after
  editing the Dockerfile: `docker build -f Dockerfile.builder -t android-builder:local .`
- **Per build**: `build.sh` spins a `docker run --rm` container and mounts three things —
  the project source at `/workspace`, the project's **own** Gradle cache at `/gradle-cache`
  (lives at `<project>/.gradle-cache/`, git-ignored, persists across builds so repeat
  builds are fast), and the APK drops back into the project's `build/outputs/apk/…`.
- Add a new app's SDK level to `Dockerfile.builder` (a `platforms;android-NN` +
  `build-tools;NN.x` line) and rebuild the image when its `compileSdk` isn't 34 or 35.

## Build → install → inspect loop

```bash
# 1) build a debug APK via the disposable container (above); or on the host directly
#    (JDK 21 is pinned globally in ~/.gradle/gradle.properties; host SDK at ~/Android/Sdk)
cd /data/android && ./build.sh ~/git/personal/<proj>
APK=~/git/personal/<proj>/app/build/outputs/apk/debug/app-debug.apk

# 2) install + launch on the emulator (via the skill's wrapper)
S=~/.claude/skills/android-dev/scripts/emulator.sh
"$S" install "$PWD/$APK"
"$S" launch <package>
"$S" screenshot /tmp/after.png
"$S" ui                      # uiautomator XML dump → REAL tap bounds
"$S" adb shell input tap <x> <y>
```

**Never guess tap coordinates from a screenshot** — the PNG may be scaled. Dump the UI
(`emulator.sh ui`) and tap the real bounds.

The container boots with `-wipe-data` (see `entrypoint.sh`), so **app state resets every
container start** — a fresh device each time. Remove the `-wipe-data` flag in
`entrypoint.sh` to persist state (server URLs, keys, logins) across restarts when testing
gets iterative.

## Publishing a finished APK to the BAM Store

When a build is *done* (not a throwaway debug iteration), publish it to the private app
store at **`/data/bam-store`** so it's installable on any of the owner's devices:

```bash
/data/bam-store/tools/publish path/to/app.apk --changelog "What changed"
```

This copies the APK into `repo/apks/<pkg>-<versionCode>.apk`, extracts metadata via
`aapt2`, and rebuilds `repo/index.json`. The `android-dev` skill documents when to do this
as part of the build workflow. Bump `versionCode` in the app's `build.gradle` before
publishing an update, or the store keeps only the highest existing code. See
`/data/bam-store/CLAUDE.md` for the repo contract and serving details.

## Storage layout

| Path | What | Where |
|---|---|---|
| `/data/storage/android/sdk` | cmdline-tools, platform-tools, emulator, system images | 15 TB array |
| `/data/storage/android/avd` | AVD config + qcow2 disks | 15 TB array |
| Docker image | JDK + emulator libs only (small) | system disk |

## Knobs (`docker-compose.yml` `environment:`)

- `EMU_MEMORY` — guest RAM MB (default 2048; the box has 48 GB, so 3072-4096 is fine —
  also bump `mem_limit`, currently 4g, if you raise it much).
- `ANDROID_API` / `ANDROID_TAG` / `ANDROID_ABI` — image selection (default Android 14 /
  `google_apis` / `x86_64`).
- `AVD_NAME` / `AVD_DEVICE` — AVD identity (default `sfit_test` / `pixel_6`).
- `entrypoint.sh` `-wipe-data` — clean device each boot; remove to persist state.

## Teardown

```bash
cd /data/android && docker compose down
# SDK + AVD persist on /data/storage/android; to reclaim that space:
# rm -rf /data/storage/android/{sdk,avd}/*
```

## Per-app notes

- **sfit** (`~/git/personal/sfit`, pkg `net.bam.sfit`) — talks to the live SparkyFitness
  server at `http://fit.bam` (host: `http://127.0.0.1:3004/api`) with an API key set in
  the app's Settings. A fresh (wiped) emulator has none, so set base URL + key first; mint
  a key in the SparkyFitness admin UI (deployment at `/data/sparkyfitness`). Features
  UI-tested here: unified food-source search (shared `FoodSourceSearch`) and negative
  ingredient quantities (`±` toggle per ingredient row).
- **trashbot capture** (`~/git/personal/trashbot/android`, pkg `com.trashbot.capture`) —
  iterate the UI/permission shell on the emulator, but the SharedCamera + manual-lock +
  RAW capture path must be tested on the **Pixel 8a** (no real camera on the emulator).

See also `README.md` here (user-facing version), the `android-dev` skill, `/data/bam-store`
(the app store), and the memory notes `android-emulator-setup` /
`android-emulator-and-phone-adb`.
