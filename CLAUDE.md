# /data/android — headless Android emulator for APK development

Purpose: a throwaway, headless Android 14 emulator driven entirely over `adb` inside a
Docker container, **plus** a disposable container that builds the APKs. It's the
fast/disposable target for building and tap-testing apps (UI, layout, navigation,
lifecycle, permission flows) before a finished build is published to the private app
store and/or installed on a physical device.

This directory holds the emulator scaffold (`Dockerfile`, `entrypoint.sh`,
`docker-compose.yml`), the build container (`Dockerfile.builder`, `build.sh`), and the
machine config (`config.yaml`). The **day-to-day workflow lives in the `android-dev`
skill** (`.claude/skills/android-dev` here) — its `scripts/emulator.sh` and
`scripts/adb-targets.sh` wrap everything below. Reach for the skill first; this file is
the reference for what the skill is driving and how to change it.

## Machine config — `config.yaml` (source of truth)

All machine-specific values (physical-device IPs, storage/app-store paths) live in
`config.yaml`, which is **git-ignored** so nothing personal is committed or published.
The tooling and this doc reference it instead of hardcoding — that keeps the repo
generic and cloneable while staying directly usable here. Set it up once:

```bash
cp config.example.yaml config.yaml     # then edit in your values
./config.sh get directories storage    # read a value
./config.sh get devices <name>         # a physical device IP
```

`config.sh` is a tiny dependency-free YAML reader (no yq/PyYAML needed). `emulator.sh`
and `docker-compose.yml` pull the storage path from it automatically. Personal per-app
notes live in the git-ignored `NOTES.local.md` (not in this committed file).

## The two isolated adb worlds (read this first)

There are two separate adb worlds on this box and they do **not** see each other:

| Target | adb path | Serial | Reach it with |
|---|---|---|---|
| **Emulator** (this dir) | in-container | `emulator-5554` | `docker exec android-emulator adb …` |
| **Physical devices** (phone, tablet) | host `/usr/bin/adb` | `<ip>:5555` (see `config.yaml`) | `adb -s <ip>:5555 …` |

The host's `/usr/bin/adb` cannot see this emulator; the emulator's in-container adb cannot
see the physical devices. `scripts/adb-targets.sh` (in the skill) lists both live, and the
friendly-name→IP map is in `config.yaml` (`devices:`). Use the emulator for UI/logic
iteration; use a physical device for anything touching real hardware (camera, ARCore,
RAW/DNG, SharedCamera, sensors) — the emulator has none of those.

A corollary: the **build container is a third adb-blind world** — Gradle's
`connectedDebugAndroidTest` runs adb there and reports "No connected devices!". Don't use it;
run instrumented (`androidTest`) suites with `scripts/connected-test.sh` (in the skill), which
builds the APKs in the builder then installs and instruments them through the emulator's own
adb. See the `android-dev` skill for details.

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
system image into `<storage>/android/sdk`, creates the AVD under `<storage>/android/avd`,
then boots (`<storage>` is `directories.storage` from `config.yaml`). All large files stay
on that big disk; the Docker image itself is small. Later runs skip straight to boot.

## Building APKs — the disposable build container (preferred)

This directory is the single front door for **building** Android APKs too, not just
running them. Rather than installing a JDK/SDK/Gradle toolchain on the host per project,
builds run in a **throwaway container** from a reusable image with the SDK baked in:

```bash
cd /data/android
./build.sh <project-dir>                        # default :app:assembleDebug
./build.sh <project-dir> :app:assembleRelease
```

- **Image** (`Dockerfile.builder`, tag `android-builder:local`) — JDK 21 (matches the
  global pin) + Android SDK platforms 34 & 35 + build-tools, all baked in and **private to
  each container**, so parallel builds never collide over a shared SDK. Rebuild it after
  editing the Dockerfile: `docker build -f Dockerfile.builder -t android-builder:local .`
- **Per build**: `build.sh` spins a `docker run --rm` container and mounts the
  project's **parent** at `/workspace`, then runs Gradle from
  `/workspace/<project-name>`. That keeps sibling repo inputs such as
  `../docs/commands.json` visible inside the container while the APK still drops
  into the project's `build/outputs/apk/…`. The project's **own** Gradle cache
  lives at `<project>/.gradle-cache/`, is mounted at `/gradle-cache`, and should be
  git-ignored.
- `build.sh` sets `HOME=/gradle-cache`, so Android's default debug keystore is
  stable per project. That prevents repeat debug installs from failing with
  `INSTALL_FAILED_UPDATE_INCOMPATIBLE` because each disposable container minted a
  new debug key. If a device already has an APK signed by an older throwaway key,
  use `run-as` to back up app data, uninstall once, install a fresh build, and
  restore the data; after that, `adb install -r` should work normally.
- Add a new app's SDK level to `Dockerfile.builder` (a `platforms;android-NN` +
  `build-tools;NN.x` line) and rebuild the image when its `compileSdk` isn't 34 or 35.

## Build → install → inspect loop

```bash
# 1) build a debug APK via the disposable container (above)
cd /data/android && ./build.sh <project-dir>
APK=<project-dir>/app/build/outputs/apk/debug/app-debug.apk

# 2) install + launch on the emulator (via the skill's wrapper)
S=/data/android/.claude/skills/android-dev/scripts/emulator.sh
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

## Publishing a finished APK to the app store

When a build is *done* (not a throwaway debug iteration), publish it to the private app
store (path in `config.yaml`, `directories.bam-store`) so it's installable on any of the
owner's devices:

```bash
STORE=$(./config.sh get directories bam-store)
"$STORE"/tools/publish path/to/app.apk --changelog "What changed"
```

This copies the APK into `repo/apks/<pkg>-<versionCode>.apk`, extracts metadata via
`aapt2`, and rebuilds `repo/index.json`. The `android-dev` skill documents when to do this
as part of the build workflow. Bump `versionCode` in the app's `build.gradle` before
publishing an update, or the store keeps only the highest existing code. See the store
repo's own docs for the contract and serving details.

## Storage layout

`<storage>` = `directories.storage` in `config.yaml` (a big disk, not the system disk).

| Path | What | Where |
|---|---|---|
| `<storage>/android/sdk` | cmdline-tools, platform-tools, emulator, system images | big disk |
| `<storage>/android/avd` | AVD config + qcow2 disks | big disk |
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
# SDK + AVD persist under <storage>/android; to reclaim that space:
# rm -rf <storage>/android/{sdk,avd}/*
```

## Per-app notes

Machine- and app-specific working notes (which app talks to which internal server, per-app
test focus, physical-device requirements) live in the **git-ignored `NOTES.local.md`** so
they stay on this box but never get published. See that file for the current apps.

See also `README.md` here (user-facing version), the `android-dev` skill, the app-store
repo (`directories.bam-store` in `config.yaml`), and the memory notes
`android-emulator-setup` / `android-emulator-and-phone-adb`.
