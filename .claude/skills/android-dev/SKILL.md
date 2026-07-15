---
name: android-dev
description: This skill should be used for Android app development on this box — building an APK with the local toolchain, installing/launching/inspecting it on the headless Dockerized emulator (/data/android), the physical Pixel 8a, or the Tab S6 Lite tablet over adb, and publishing finished APKs to the private BAM Store app store (/data/bam-store). It knows the box's two isolated adb worlds and how to target each. Use when the user wants to build, run, install, test, or debug an Android app; drive or boot the emulator; connect to the phone; take a screenshot or logcat; dump the UI; see which devices adb sees; or publish/release a finished APK to the app store. Triggers on: android, emulator, adb, apk, gradle, install app, run on emulator/phone/tablet, Pixel 8a, akita, Tab S6 Lite, stab, logcat, screenshot the app, uiautomator, avd, build the app, publish app, release apk, bam store, app store.
---

# Android development on this box

Build an Android app with the local toolchain, then install/launch/inspect it on
one of two targets. The scripts in `scripts/` are the fast path; the rest is context.

## The one thing to internalize: two isolated adb worlds

| Target | adb path | Typical serial | Reach it with |
|---|---|---|---|
| **Physical Pixel 8a** ("akita") | host `/usr/bin/adb` | `100.64.0.3:5555` (tailnet) | `adb -s <serial> …` |
| **Physical Tab S6 Lite** ("stab", SM-P620, Android 16) | host `/usr/bin/adb` | `100.64.0.5:5555` (tailnet) | `adb -s <serial> …` |
| **Headless emulator** (Android 14) | **in-container** | `emulator-5554` | `docker exec android-emulator adb …` |

They do **not** see each other — the host adb server has no view of the emulator,
and the emulator's in-container adb has no view of the phone. Always pick the world
that matches the target. `scripts/adb-targets.sh` lists both at once.

## Toolchain / build

- Android SDK: `~/Android/Sdk` (`android/local.properties` points here).
- **JDK 21** is pinned globally in `~/.gradle/gradle.properties`
  (`org.gradle.java.home=/home/bam/opt/jdk-21.0.11+10`) — the system JDK is too new
  for Gradle. Every Gradle build on this box uses it automatically; don't override.
- Build (from a project's `android/` dir, or the app root for other projects):

```sh
./gradlew :app:clean :app:assembleDebug   # -> app/build/outputs/apk/debug/app-debug.apk
./gradlew installDebug                     # build + install to connected HOST devices (the phone)
```

> **Always `clean` before an APK you'll install on a device.** Kotlin Multiplatform
> incremental builds can silently ship a **stale shared-module dex**: a `commonMain`
> data class (e.g. a wire model like `HelloConfig`) doesn't get re-dexed while the
> `androidMain` caller does, so the installed app throws `NoSuchMethodError` on the
> changed constructor/method **at launch** — a crash the emulator won't reproduce if it
> ran a different incremental artifact. Either prefix `clean`, or install the *exact same
> APK* you tap-tested on the emulator onto the phone (don't rebuild in between).

`installDebug` targets host-adb devices only (i.e. the phone). For the emulator,
build the APK then push it through the container (see below). If several host
devices are attached, set `ANDROID_SERIAL=<serial>` so Gradle/adb pick one.

## Detect targets

```sh
scripts/adb-targets.sh
```

Prints the phone (host adb) and the emulator (container adb) with state + boot flag.
Run this first whenever you're unsure what's connected.

## Emulator (Dockerized, at /data/android)

A throwaway headless Android 14 emulator, KVM-accelerated, driven entirely over
`docker exec android-emulator adb`. `scripts/emulator.sh` wraps the common ops:

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

Details, knobs (`EMU_MEMORY`, `ANDROID_API`, `-wipe-data`), storage layout, and
teardown live in `/data/android/README.md` and `/data/android/CLAUDE.md`. The
container boots with `-wipe-data`, so app state resets each container start.

**Do NOT screenshot-guess tap coordinates** — the screenshot may be scaled. Dump
the UI (`emulator.sh ui`) and tap the real bounds:
`emulator.sh adb shell input tap <x> <y>`.

## Physical devices (over host adb)

```sh
adb devices -l                                  # 100.64.0.3:5555 = Pixel_8a, 100.64.0.5:5555 = SM_P620 tablet
adb -s 100.64.0.3:5555 install -r <apk>
adb -s 100.64.0.3:5555 shell monkey -p <pkg> -c android.intent.category.LAUNCHER 1
adb -s 100.64.0.3:5555 exec-out screencap -p > /tmp/phone.png
```

Both run a persistent adbd on port 5555 (`adb tcpip 5555`), reached over the
tailnet. That survives sleep/reconnect but **not a device reboot** — after a
reboot, re-pair via wireless debugging (device + host reachable, e.g. tailnet):

```sh
adb pair <ip>:<pair-port>          # 6-digit code from "Pair device with pairing code"
adb connect <ip>:<connect-port>    # connect-port is from the main Wireless debugging screen;
                                   # if unknown, port-scan 30000-49999 on the device
adb -s <ip>:<connect-port> tcpip 5555 && adb connect <ip>:5555   # back to the stable port
```

Over USB, a **charge-only cable won't enumerate** the phone (`lsusb` shows no
Google `18d1` device) — use a known data cable or wireless debugging.

## Which target for which work

- **Emulator** — UI, layout, navigation, lifecycle, permission flows, quick
  iteration. Fast and disposable.
- **Phone** — anything touching real hardware: **camera, ARCore, RAW/DNG,
  SharedCamera, sensors**. The emulator has no real camera and no Play Services
  for AR, so those cannot be validated there.

For the **trashbot capture app** (`~/git/personal/trashbot/android`, pkg
`com.trashbot.capture`) this means: iterate the UI/permission shell on the
emulator, but the SharedCamera + manual-lock + RAW capture path must be tested on
the Pixel 8a.

## Publishing a finished APK to the BAM Store

Once a build is *finished* — a real release, not a throwaway debug iteration you're
still tapping through — publish it to the private app store at **`/data/bam-store`** so
it's installable on any of the owner's devices via the BAM Store client app. This is the
last step of the build workflow for a shippable APK.

```sh
/data/bam-store/tools/publish path/to/app.apk --changelog "What changed"
```

`publish` extracts the package name, version, icon, and size with `aapt2`, copies the APK
to `repo/apks/<pkg>-<versionCode>.apk`, records the changelog, and regenerates
`repo/index.json` (one entry per package, highest `versionCode` wins).

- **Publish the release APK, not the debug one**, when the store version is meant for real
  use: `./gradlew :app:assembleRelease` → `app/build/outputs/apk/release/*.apk`. A debug
  APK is fine for a quick internal drop, but note the store keeps only the highest
  `versionCode`, so mixing debug/release builds of the same code is confusing.
- **Bump `versionCode`** (and usually `versionName`) in the app's `build.gradle` before
  publishing an update — the store dedupes by package and keeps only the highest
  `versionCode`, so a re-publish at the same code won't surface as a new version.
- After publishing, `tools/reindex` re-derives `index.json` from whatever APKs are in
  `repo/apks/` (use it after manually deleting/replacing an APK).
- The publish tools need the Android SDK on `ANDROID_HOME` (default `~/Android/Sdk`) for
  `aapt2`. See `/data/bam-store/CLAUDE.md` for the `index.json` contract and how the repo
  is served (static files behind Caddy).

Guidance on *when*: after the user confirms a build works (on emulator and/or phone) and
asks to ship/release/publish it, or when finishing an app they intend to install on their
own devices. Don't auto-publish every debug build — only finished ones, and confirm the
changelog text with the user if it's not obvious.

## Typical loop

```sh
scripts/adb-targets.sh                                   # see what's connected
cd ~/git/personal/<proj>/android && ./gradlew :app:clean :app:assembleDebug -q
APK=app/build/outputs/apk/debug/app-debug.apk
# emulator:
scripts/emulator.sh up                                   # if not already booted
scripts/emulator.sh install "$PWD/$APK"
scripts/emulator.sh launch com.example.app
scripts/emulator.sh screenshot /tmp/after.png
# phone:
adb -s 100.64.0.3:5555 install -r "$APK" && adb -s 100.64.0.3:5555 shell monkey -p com.example.app -c android.intent.category.LAUNCHER 1
```
