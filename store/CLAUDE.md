# store/ — the BAM Store spoke

The **store spoke** of the docs map in `/data/android/CLAUDE.md`. That root file is the
hub: conventions, the container-first style guide, the two adb worlds, `build.sh` and
its automatic publish step all live there, and `README.md` there owns the user-facing
commands and env knobs. This file owns only what is specific to the store: the
`repo/index.json` contract, what's committed versus generated, and how the repo is
served.

## What this is

A private, self-hosted Android app store — a personal F-Droid — distributing the apps
built on this box to the owner's own devices. It is `repo/` + `tools/`: a *static*
repository (a directory of APKs + a generated `index.json`) and a Python CLI that
publishes into it. No server code, no database; the repo is served as static files by
Caddy.

Every published APK is also mirrored into a **signed F-Droid-format repo**, and that
is now the only client story — the standard F-Droid app subscribes to it. The toolbox
and its scripts are owned by the root `CLAUDE.md` → "The F-Droid repo container".

**The custom `com.bam.store` client was retired** (2026-08-05) rather than reworked to
parse `index-v2.json`: the F-Droid app already does signed indexes, updates, and the
install flow correctly. `store/client/` and the published `com.bam.store` APKs are
gone. `index.json` stays because the tools and the F-Droid mirror are both built on
it; treat it as an internal format with no external consumer.

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

## Using the repo from the F-Droid app

Add the signed F-Droid repo in the F-Droid app (URL and fingerprint below, under
"Serving the repo"). Installs then go through F-Droid's own flow — it asks for the
"Install unknown apps" permission once, and handles updates from the signed index.

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
documents the same block for reference.

**The F-Droid repo** is served separately at **`http://fdroid.bam/repo`** (`fdroid.url`
in `config.yaml`), out of `directories.fdroid-repo`. That is the URL to add in the
F-Droid app, with the signing key's fingerprint:

```
http://fdroid.bam/repo?fingerprint=11706E44EBB05B2D842097C34671D7C1BC14F52450693C48D800CAC5B00BC5C1
```

**Plain HTTP is intentional.** Everything is reached over Tailscale, which already
encrypts and authenticates the connection, so TLS would just re-wrap an encrypted
tunnel. `apps.bam` is a MagicDNS name resolving to this box (`100.64.0.2`) — the
same `*.bam` pattern as the box's other tailnet sites; no public DNS is involved.
Both the emulator (via the container's inherited DNS) and the Pixel 8a resolve it.

**Auth is off** — access is limited by Tailscale ACLs, and the F-Droid index is
signed, so tampering is detectable even without transport auth. To gate the repo,
add a token check to the Caddy record.
