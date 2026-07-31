---
name: android-dev
description: This skill should be used for Android app development on this box — building an APK in the disposable build container (/data/android/build.sh), installing/launching/inspecting it on the headless Dockerized emulator, a physical phone, or a tablet over adb, and publishing finished APKs to the private app store. It knows the box's two isolated adb worlds and how to target each. Use when the user wants to build, run, install, test, or debug an Android app; drive or boot the emulator; connect to a physical device; take a screenshot or logcat; dump the UI; see which devices adb sees; or publish/release a finished APK. Triggers on: android, emulator, adb, apk, gradle, install app, run on emulator/phone/tablet, logcat, screenshot the app, uiautomator, avd, build the app, publish app, release apk, app store.
---

# Android development on this box

Build an Android app in the disposable build container, then install/launch/inspect
it on one of two adb worlds. The scripts in `scripts/` are the fast path; the rest is
context. Machine-specific values (device IPs, storage/app paths) live in
`/data/android/config.yaml` (git-ignored) — read them with `config.sh`, never hardcode.

## The one thing to internalize: two isolated adb worlds

| Target | adb path | Reach it with |
|---|---|---|
| **Physical devices** (phone, tablet) | host `/usr/bin/adb` | `adb -s <ip>:5555 …` |
| **Headless emulator** (Android 14) | **in-container** | `docker exec android-emulator adb …` |

They do **not** see each other — the host adb server has no view of the emulator, and
the emulator's in-container adb has no view of the physical devices. Always pick the
world that matches the target. `scripts/adb-targets.sh` lists both live, and the
friendly-name→IP map for physical devices is in `config.yaml` (`devices:`).

## Build an APK — the disposable container

Builds run in a throwaway container from a baked image (JDK 21 + Android SDK), so no
JDK/SDK/Gradle toolchain is installed on the host:

```sh
/data/android/build.sh <project-dir> [gradle-task]   # default :app:assembleDebug
```

- Per-project Gradle cache lives at `<project>/.gradle-cache` (git-ignore it) and
  persists across builds, so repeats are fast. `build.sh` mounts the project's
  **parent** at `/workspace` and runs Gradle from `/workspace/<project-name>`, so
  sibling repo inputs such as `../docs/commands.json` are visible inside the
  container. APKs still land in the project's `build/outputs/apk/…`.
- The build container sets `HOME=/gradle-cache`, so Android's default debug
  keystore is stable per project. That keeps future `adb install -r` upgrades from
  failing with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. If an already-installed app
  was signed by an older throwaway key, back up app data with `run-as`, uninstall
  once, install the new APK, then restore the data; after that, normal `install -r`
  works.
- Add a new app's SDK level to `/data/android/Dockerfile.builder` and rebuild the
  image (`docker build -f Dockerfile.builder -t android-builder:local .`) when its
  `compileSdk` isn't already baked in.

> **`clean` before an APK you'll install on a physical device.** Kotlin Multiplatform
> incremental builds can silently ship a **stale shared-module dex**: a `commonMain`
> data class doesn't get re-dexed while the `androidMain` caller does, so the app throws
> `NoSuchMethodError` at launch. Either prefix `:app:clean`, or install the *exact same
> APK* you tap-tested on the emulator onto the device (don't rebuild in between).

## Detect targets

```sh
scripts/adb-targets.sh
```

Prints the physical devices (host adb) and the emulator (container adb) with state +
boot flag. Run this first whenever you're unsure what's connected.

## Emulator (Dockerized, at /data/android)

A throwaway headless Android 14 emulator, KVM-accelerated, driven over `docker exec
android-emulator adb`. `scripts/emulator.sh` wraps the common ops (it reads
`config.yaml` for the storage path automatically):

```sh
scripts/emulator.sh status              # up? booted? which Android?
scripts/emulator.sh up                  # docker compose up -d + wait for boot
scripts/emulator.sh install <apk>       # docker cp + adb install -r
scripts/emulator.sh launch <package>    # start the launcher activity
scripts/emulator.sh screenshot [file]   # PNG (default /tmp/emu-screen.png)
scripts/emulator.sh ui                  # uiautomator XML dump — real tap coords
scripts/emulator.sh logcat / shell / adb   # passthroughs
scripts/emulator.sh down
```

The container boots with `-wipe-data`, so app state resets each container start.
Knobs (`EMU_MEMORY`, `ANDROID_API`, `-wipe-data`) and storage layout live in
`/data/android/README.md` and `/data/android/CLAUDE.md`.

**Do NOT screenshot-guess tap coordinates** — the screenshot may be scaled. Dump the
UI (`emulator.sh ui`) and tap the real bounds:
`emulator.sh adb shell input tap <x> <y>`.

## Instrumented (`androidTest`) tests — `scripts/connected-test.sh`

Do **not** run Gradle's `connectedDebugAndroidTest`: it starts an adb server inside the
throwaway build container (a different adb world than the emulator) and dies with
"No connected devices!". Instead:

```sh
scripts/connected-test.sh <project-dir>                         # build + run the whole suite
scripts/connected-test.sh <project-dir> -e class com.foo.BarTest  # args pass to `am instrument`
```

It builds the app + `androidTest` APKs in the builder container, reads the instrumentation
component from the test APK's manifest (aapt), then installs and runs it through the
**emulator container's own adb** — the one adb that can see the emulator. Both halves stay in
the world where they work. Exit status is the test result (non-zero if any test fails/errors
or the runner can't start), so it's CI-usable. Booting the emulator first is handled for you.

## Physical devices (over host adb)

Get the device IP from `config.yaml` (`./config.sh get devices <name>`), or run
`adb-targets.sh` to see live serials:

```sh
IP=$(cd /data/android && ./config.sh get devices <name>)   # e.g. the phone
adb -s "$IP":5555 install -r <apk>
adb -s "$IP":5555 shell monkey -p <pkg> -c android.intent.category.LAUNCHER 1
adb -s "$IP":5555 exec-out screencap -p > /tmp/phone.png
```

Physical devices run a persistent adbd on port 5555 (`adb tcpip 5555`), reached over
the network. That survives sleep/reconnect but **not a device reboot** — after a
reboot, re-pair via wireless debugging:

```sh
adb pair <ip>:<pair-port>          # 6-digit code from "Pair device with pairing code"
adb connect <ip>:<connect-port>    # connect-port from the main Wireless debugging screen
adb -s <ip>:<connect-port> tcpip 5555 && adb connect <ip>:5555   # back to the stable port
```

Over USB, a **charge-only cable won't enumerate** the device — use a data cable or
wireless debugging.

## Which target for which work

- **Emulator** — UI, layout, navigation, lifecycle, permission flows, quick iteration.
  Fast and disposable.
- **Physical device** — anything touching real hardware: **camera, ARCore, RAW/DNG,
  SharedCamera, sensors**. The emulator has no real camera and no Play Services for AR,
  so those cannot be validated there.

## Publishing a finished APK to the app store

Once a build is *finished* (a real release, not a throwaway debug iteration), publish
it to the private app store so it's installable on any of the owner's devices. The
store lives at the `bam-store` path in `config.yaml` (`./config.sh get directories
bam-store`); see that repo's own docs for the contract.

```sh
STORE=$(cd /data/android && ./config.sh get directories bam-store)
"$STORE"/tools/publish path/to/app.apk --changelog "What changed"
```

`publish` extracts the package/version/icon/size with `aapt2`, copies the APK into the
store repo, records the changelog, and regenerates the index (highest `versionCode`
wins per package).

- **Publish the release APK, not the debug one**, for real use
  (`:app:assembleRelease`). **Bump `versionCode`** (and usually `versionName`) before
  re-publishing an update, or the store won't surface it as new.
- Confirm the changelog text with the user if it's not obvious. Don't auto-publish
  every debug build — only finished ones the user asks to ship.

## Typical loop

```sh
scripts/adb-targets.sh                                   # see what's connected
/data/android/build.sh <project-dir> :app:assembleDebug  # APK in build/outputs/apk/debug/
# emulator:
scripts/emulator.sh up                                   # if not already booted
scripts/emulator.sh install <project>/app/build/outputs/apk/debug/app-debug.apk
scripts/emulator.sh launch <package>
scripts/emulator.sh screenshot /tmp/after.png
# physical device:
IP=$(cd /data/android && ./config.sh get devices <name>)
adb -s "$IP":5555 install -r <apk> && adb -s "$IP":5555 shell monkey -p <package> -c android.intent.category.LAUNCHER 1
```
