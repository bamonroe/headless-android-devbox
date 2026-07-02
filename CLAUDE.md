# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A private, self-hosted Android app store — a personal F-Droid. It distributes the
apps *the owner builds* to their own Pixel devices. Two independent pieces:

- **`client/`** — a native Kotlin + Jetpack Compose Android app (`com.bam.store`)
  that fetches a catalog over HTTPS, downloads APKs, and installs them via the
  platform `PackageInstaller`.
- **`repo/`** + **`tools/`** — a *static* repository (a directory of APKs + a
  generated `index.json`) and a Python CLI that publishes into it. No server code,
  no database; the repo is meant to be served as static files by Caddy.

The client talks to the repo over plain HTTP(S): `GET index.json`, then
`GET apks/<file>`. That contract (see below) is the only coupling between the two
halves — either can be rebuilt independently as long as the JSON shape holds.

## Repository contract (`repo/index.json`)

`tools/` generates it; the client parses it (`data/Models.kt`). Keep the two in
sync — a field rename touches both `storelib.py` (`AppMeta`) and `Models.kt`.

```json
{
  "repo": { "name": "BAM Store" },
  "apps": [{
    "packageName": "…", "label": "…", "versionName": "…", "versionCode": 1,
    "minSdk": 29, "size": 123, "sha256": "…",
    "apk": "apks/<pkg>-<versionCode>.apk",   // repo-relative
    "icon": "icons/<pkg>.png",               // repo-relative, or null
    "changelog": "…"                         // or null
  }]
}
```

`apk`/`icon` are **repo-relative**; the client resolves them against its
configured base URL. One entry per package (highest `versionCode` wins).

## Common commands

Run from the repo root. The publish tools need the Android SDK on
`ANDROID_HOME` (defaults to `~/Android/Sdk`) for `aapt2`.

```bash
# Publish an APK into the store (extracts metadata, copies APK, rebuilds index)
tools/publish path/to/app.apk --changelog "What changed"

# Rebuild repo/index.json from whatever APKs are in repo/apks/ (after manual edits)
tools/reindex

# Build the client
cd client && ./gradlew :app:assembleDebug          # debug APK
cd client && ./gradlew :app:assembleRelease         # release APK
cd client && ./gradlew :app:installDebug            # build + adb install to current device

# There are no unit tests yet. `./gradlew test` is the hook when they exist.
```

Client APK output: `client/app/build/outputs/apk/debug/app-debug.apk`.

## Toolchain (this box)

- Android SDK: `/home/bam/Android/Sdk` (build-tools 35.0.0, platform android-35).
  `client/local.properties` pins `sdk.dir` and is **not** committed — regenerate on
  a new machine.
- Gradle 8.10.2 (wrapper), AGP 8.7.2, Kotlin 2.0.21, JDK 17 target.
- The `publish`/`reindex` tools call `aapt2` from the newest `build-tools/*` and
  parse `aapt2 dump badging`. Note the field is `minSdkVersion:'…'` (capital S) —
  a `sdkVersion` regex silently matches nothing.

## Installing / running on a device

Two **isolated adb worlds** live on this box (see the `android-dev` skill for the
full story): the Dockerized emulator under `/data/android`, and the physical
Pixel 8a. `adb` targets one or the other depending on which is connected — always
confirm with `adb devices` before an install. Use the `android-dev` skill to
build+install+inspect rather than driving adb by hand.

For `adb install -r` to upgrade the client in place across rebuilds, the debug
signature must be stable. Point `BAM_STORE_DEBUG_KEYSTORE` at a fixed debug
keystore before building (see `client/app/build.gradle.kts`); otherwise
containerized builds mint a random debug key each time and reinstalls fail with a
signature mismatch.

## The install flow (the part that actually matters)

`com.bam.store` is an *ordinary* installer, not a privileged/system one, so every
install requires the user to confirm a system dialog. The flow spans three files:

1. `data/RepoClient.kt` streams the APK into `cacheDir`.
2. `install/ApkInstaller.kt` opens a `PackageInstaller` session, writes the APK,
   and commits with a `PendingIntent` (must be `FLAG_MUTABLE` on API 31+).
3. `install/InstallResultReceiver.kt` receives the session callback. The normal
   path is `STATUS_PENDING_USER_ACTION` → it launches the OS confirm dialog.
   Terminal success/failure is republished on the process-static
   `InstallEvents` flow that `MainActivity` collects.

The app declares `REQUEST_INSTALL_PACKAGES`, but the user must *also* grant
"Install unknown apps" to it once in system settings, or every install is
rejected. `QUERY_ALL_PACKAGES` is what lets the catalog show installed-vs-update
state (`PackageManager.getPackageInfo`).

## Serving the repo

`repo/Caddyfile.example` is the starting point. The client defaults to the
placeholder `https://store.bam/` (`data/Settings.kt`); real DNS + Caddy get wired
up with the `dns` and `caddy` skills once a hostname is chosen. For a private repo,
gate it behind a bearer token — the client sends `Authorization: Bearer <token>`
on every request (index, APK, and icon) when a token is set in its settings.
