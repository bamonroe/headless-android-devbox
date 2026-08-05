# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A private, self-hosted Android app store — a personal F-Droid. It distributes the
apps *the owner builds* to their own Pixel devices. Two independent pieces:

- **`client/`** — a native Kotlin + Jetpack Compose Android app (`com.bam.store`)
  that fetches a catalog over HTTP(S), downloads APKs, and installs them via the
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

### What's committed vs. generated

The APK binaries do not live beside the tools at all: `BAM_STORE_APKS` points
them at the big disk (`directories.bam-store-apks` in `/data/android/config.yaml`,
currently `/data/storage/bam-store/apks`), because 300+ MB of payload must never
land on the system disk or in git. `tools/publish` and `tools/reindex` read that
variable; `/data/android/build.sh` exports it automatically. The changelog
sidecars stay in `repo/apks/` inside git, and the index still advertises
`apks/<file>` — the server maps that prefix at the payload dir (see
`repo/Caddyfile.example`).

`index.json`, the APK binaries (`repo/apks/*.apk`), and extracted icons
(`repo/icons/*`) are all **gitignored** — they are the store's payload/derived
artifacts, regenerable from the APKs with `tools/reindex`. What *is* committed is
each APK's **changelog sidecar**: `repo/apks/<pkg>-<versionCode>.json`, a tiny
`{"changelog": "…"}` file that `tools/publish --changelog` writes and `reindex`
reads back so changelog text survives an index rebuild even though the binaries
don't live in git. So: to preserve a changelog, keep its sidecar; to change one,
edit the sidecar and re-run `tools/reindex`.

## Common commands

Run from the repo root. The publish tools read APK metadata with `aapt2` from the
`android-builder:local` container (`tools/aapt2.py`) — no host SDK required. They
fall back to a host `aapt2` (under `ANDROID_HOME`/build-tools, or on `PATH`) only
if one exists. The env knobs (`BAM_STORE_AAPT2`, `BAM_STORE_BUILDER_IMAGE`, and
the rest) are listed in `/data/android/README.md` → "Environment knobs (build +
publish)".

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
- The `publish`/`reindex` tools parse `aapt2 dump badging`, run in the builder
  container by default. Note the field is `minSdkVersion:'…'` (capital S) —
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
   and commits with a `PendingIntent` (must be `FLAG_MUTABLE` on API 31+). The
   status `Intent` **must name `InstallResultReceiver` by explicit component**
   (`Intent(context, InstallResultReceiver::class.java)`) — the receiver is a
   manifest receiver with no `<intent-filter>`, so an action-only broadcast is
   silently never delivered, the confirm dialog never launches, and the install
   hangs after download. (This was a real bug; don't reintroduce it.)
3. `install/InstallResultReceiver.kt` receives the session callback. The normal
   path is `STATUS_PENDING_USER_ACTION` → it launches the OS confirm dialog.
   Terminal success/failure is republished on the process-static
   `InstallEvents` flow that `MainActivity` collects.

The app declares `REQUEST_INSTALL_PACKAGES`, but the user must *also* grant
"Install unknown apps" to it once in system settings, or every install is
rejected. `QUERY_ALL_PACKAGES` is what lets the catalog show installed-vs-update
state (`PackageManager.getPackageInfo`).

## Serving the repo

**Live deployment:** the repo is served at **`http://apps.bam/`** over the tailnet
by a Caddy static-file record:

```
apps.bam:80 {
	root * /data/android/store/repo
	file_server
}
```

That record is managed through the **`caddyedit` Record API (the `caddy` skill)**,
not by hand-editing `/etc/caddy/Caddyfile` — to change the route (port, path, add a
token matcher), mutate the `apps.bam:80` record and apply. `repo/Caddyfile.example`
documents the same block for reference. The client defaults to `http://apps.bam/`
(`data/Settings.kt`).

**Plain HTTP is intentional.** Everything is reached over Tailscale, which already
encrypts and authenticates the connection, so TLS would just re-wrap an encrypted
tunnel. `apps.bam` is a MagicDNS name resolving to this box (`100.64.0.2`) — the
same `*.bam` pattern as the box's other tailnet sites; no public DNS is involved.
Both the emulator (via the container's inherited DNS) and the Pixel 8a resolve it.

**Auth is currently off** — access is limited by Tailscale ACLs. The client still
supports a bearer token: set one in its settings and it sends
`Authorization: Bearer <token>` on every request (index, APK, and icon). To gate
the repo, add a matching token check to the `apps.bam` Caddy record.
