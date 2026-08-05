# store/ — the BAM Store spoke

The **store spoke** of the docs map in `/data/android/CLAUDE.md`. That root file is the
hub: conventions, the container-first style guide, the two adb worlds, `build.sh` and
its automatic publish step all live there, and `README.md` there owns the user-facing
commands and env knobs. This file owns only what is specific to the store: the
`repo/index.json` contract, what's committed versus generated, the `com.bam.store`
client's install flow, and how the repo is served.

## What this is

A private, self-hosted Android app store — a personal F-Droid — distributing the apps
built on this box to the owner's own devices. Two independent pieces:

- **`client/`** — a native Kotlin + Jetpack Compose Android app (`com.bam.store`)
  that fetches a catalog over HTTP(S), downloads APKs, and installs them via the
  platform `PackageInstaller`.
- **`repo/`** + **`tools/`** — a *static* repository (a directory of APKs + a
  generated `index.json`) and a Python CLI that publishes into it. No server code,
  no database; the repo is served as static files by Caddy.

The client talks to the repo over plain HTTP(S): `GET index.json`, then
`GET apks/<file>`. That contract (below) is the only coupling between the two
halves — either can be rebuilt independently as long as the JSON shape holds.

The store is also mirrored into an F-Droid-format repo; that toolbox and its
scripts are owned by the root `CLAUDE.md` → "The F-Droid repo container".

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

## The tools (`tools/publish`, `tools/reindex`)

`/data/android/build.sh` runs the publisher automatically after every successful
build, so publishing by hand is the exception — reach for these when adopting an
APK built elsewhere or repairing the index:

```bash
tools/publish path/to/app.apk --changelog "What changed"   # extract, copy, reindex
tools/reindex                                              # rebuild index.json from repo/apks/
```

They read APK metadata with `aapt2` inside the `android-builder:local` container
(`tools/aapt2.py`) — no host SDK required — falling back to a host `aapt2` only if
one exists. Env knobs (`BAM_STORE_AAPT2`, `BAM_STORE_BUILDER_IMAGE`, and the rest)
are listed once in `/data/android/README.md` → "Environment knobs (build +
publish)". One parsing gotcha worth keeping: the badging field is
`minSdkVersion:'…'` with a capital S, so a `sdkVersion` regex silently matches
nothing.

## Building and installing the client

Build `client/` like any other app here — through the disposable build container
(`/data/android/build.sh client`), which also publishes the resulting APK into this
store. Installing and driving it on the emulator or a physical device is the
`android-dev` skill's job; don't hand-drive adb. Both are covered by the root
`CLAUDE.md`, which also explains why the debug keystore is pinned per project so
`adb install -r` keeps working across rebuilds.

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
