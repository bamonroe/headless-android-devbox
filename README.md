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
build, and a per-project Gradle cache at `<project>/.gradle-cache`. `build.sh`
mounts the project's parent directory, not only the Gradle root, so builds that
read sibling files such as `../docs/commands.json` work without custom Docker
commands. It also keeps `HOME` inside the Gradle cache, which gives each project a
stable debug keystore for repeat `adb install -r` upgrades.

After a successful APK-producing build, `build.sh` publishes the new APK(s) into
the in-repo BAM Store at `store/` (override with `config.yaml`
`directories.bam-store`), making them available
through the private app repo.

The store itself now lives in this repo under `store/`. Its APK payload does not:
`config.yaml` `directories.bam-store-apks` points the binaries at the big disk
(`build.sh` passes it through as `BAM_STORE_APKS`), so hundreds of MB of APKs stay
off the system disk and out of git while `store/repo/` keeps the small, committed
parts. Serving maps `/apks/` at the payload dir — see `store/repo/Caddyfile.example`.

### Environment knobs (build + publish)

This table is the authoritative list; `build.sh`'s header points here.

| Variable | Read by | Default | What it does |
|---|---|---|---|
| `BAM_STORE_PUBLISH` | `build.sh` | `1` | `0` builds only — no store publish (scratch builds). |
| `BAM_STORE_CHANGELOG` | `build.sh` | `Built by /data/android/build.sh` | Changelog text for the sidecar `tools/publish` writes. |
| `BAM_STORE_APKS` | `tools/publish`, `tools/reindex` | `directories.bam-store-apks` from `config.yaml`, else `store/repo/apks` | Where APK **binaries** land (the big disk). `build.sh` exports it from `config.yaml`. |
| `BAM_STORE_REPO` | store tools | `store/repo` | The store repo dir holding `index.json`, icons, changelog sidecars. |
| `BAM_STORE_AAPT2` | store tools | unset | Force a specific `aapt2` binary instead of running it in the builder container. |
| `BAM_STORE_BUILDER_IMAGE` | store tools | `android-builder:local` | Image used to run `aapt2 dump badging`. Falls back to `BUILDER_IMAGE`. |
| `BUILDER_IMAGE` | `build.sh`, store tools | `android-builder:local` | The build container image. |

The pre-merge checkout at `/data/bam-store` is gone; `http://apps.bam/` now
serves straight out of `store/repo`. Caddy runs as the `/data/caddy-docker` container, so its
`apps.bam` root is bind-mounted there, and the Caddyfile itself is edited
through the `/data/caddyedit` API rather than by hand.

## F-Droid repo toolbox

The APK repo is moving to an F-Droid-style repo with a signed index. The tooling for
that is a third container (`Dockerfile.fdroid`, tag `fdroid:local`) built on top of
the builder image, so it reuses the same JDK + Android SDK (`aapt2`, `apksigner`):

```bash
docker build -f Dockerfile.builder -t android-builder:local .   # once, if missing
docker build -f Dockerfile.fdroid  -t fdroid:local .

scripts/fdroid-keystore.sh      # ONCE: create the repo signing key (see below)
scripts/fdroid.sh init --keystore /keystore --repo-keyalias <alias> --no-prompt
scripts/fdroid-config.sh        # write config.yml (identity + key) from config.yaml
scripts/fdroid-publish.sh       # the day-to-day one: sync APKs + metadata, then update
scripts/fdroid.sh deploy        # push the repo to its serving location
scripts/fdroid.sh shell         # interactive poke-around
```

`scripts/fdroid-publish.sh` is what `build.sh` runs automatically after a successful
BAM Store publish, so a normal build lands in **both** indexes. It just sequences the
three steps, each of which is still runnable on its own:

```bash
scripts/fdroid-sync-apks.sh     # store APK binaries   -> <fdroid-repo>/repo/
scripts/fdroid-metadata.sh      # store index.json     -> <fdroid-repo>/metadata/
scripts/fdroid.sh update -c     # rescan APKs, regenerate + sign the index
```

`scripts/fdroid-metadata.sh` projects the store's `index.json` into the per-package
`metadata/<pkg>.yml` (Name, Summary, Description, License, Categories) and turns each
changelog sidecar into `metadata/<pkg>/en-US/changelogs/<versionCode>.txt`. It
**preserves** anything already written in a yml, so hand-editing an app's Summary or
License sticks; only empty fields get defaults. `CurrentVersionCode` is the exception
— it always tracks the store's latest release, because `fdroid update` only surfaces
the changelog file whose name matches it. That changelog shows up as `whatsNew` in
`index-v1.json`; `index-v2.json` only carries per-version changelogs for *source*-built
repos, so a binary repo like this one has none there. Icons are **not** staged: `fdroid
update` extracts and rescales them straight from each APK into `repo/icons-*/`. The
only exception is an app the store did manage to extract an icon for, which is copied
to `metadata/<pkg>/en-US/icon.png` as an override.

`scripts/fdroid.sh` runs a throwaway container as your own uid (nothing comes back
root-owned) and reads its paths from `config.yaml`: `directories.fdroid-repo` is
mounted at `/repo` and `directories.fdroid-keystore` read-only at `/keystore`. The
repo's public URL, name, description and key alias live in the `fdroid:` section of
`config.yaml`. The same image is also a `tools`-profile compose service, so
`docker compose --profile tools run --rm fdroid fdroid update` works; it never starts
with a plain `docker compose up`.

| Variable | Read by | Default | What it does |
|---|---|---|---|
| `FDROID_IMAGE` | `scripts/fdroid.sh`, `scripts/fdroid-keystore.sh` | `fdroid:local` | The fdroidserver container image. |
| `FDROID_REPO` | `scripts/fdroid.sh`, compose | `directories.fdroid-repo` from `config.yaml` | Repo dir mounted at `/repo`. |
| `FDROID_KEYSTORE` | `scripts/fdroid.sh`, `scripts/fdroid-keystore.sh`, compose | `directories.fdroid-keystore` from `config.yaml` | Signing keystore mounted read-only at `/keystore`. |
| `FDROID_KEY_ALIAS` | `scripts/fdroid-keystore.sh` | `fdroid.keystore-alias` from `config.yaml` | Key alias inside the keystore. |
| `FDROID_KEY_DNAME` | `scripts/fdroid-keystore.sh` | `CN=<fdroid.name>, OU=fdroid` | X.500 name on the self-signed cert. |
| `BAM_STORE_APKS` | `scripts/fdroid-sync-apks.sh` | `directories.bam-store-apks` from `config.yaml` | Where the store's APK binaries are read from. |
| `BAM_STORE` | `scripts/fdroid-metadata.sh` | `directories.bam-store` from `config.yaml`, else `store/` | The store dir whose `repo/index.json` metadata is generated from. |
| `FDROID_AUTHOR` | `scripts/fdroid-metadata.sh` | `fdroid.author` from `config.yaml` | `AuthorName` filled in for apps that don't have one yet. |
| `FDROID_PUBLISH` | `build.sh`, `tools/publish`, `tools/reindex` | `1` | `0` publishes to the BAM Store only — no F-Droid repo update. `build.sh` sets it for its per-APK publishes and runs the F-Droid step once at the end. |
| `FDROID_PUBLISH_SCRIPT` | `tools/publish`, `tools/reindex` | `<android>/scripts/fdroid-publish.sh` | The second indexer they call; skipped with a warning if it isn't executable. |

### The repo layout, and what's committed

The whole F-Droid repo lives **outside git**, at `directories.fdroid-repo` on the big
disk — everything in it is a build artifact rebuildable from the APKs and
`config.yaml`:

| Path | What |
|---|---|
| `<fdroid-repo>/config.yml` | generated by `scripts/fdroid-config.sh`; **contains the keystore password**, mode 0600 |
| `<fdroid-repo>/repo/` | the published APKs plus `index-v1.json`/`index-v2.json`, `index.jar`/`entry.jar` (signed), icons |
| `<fdroid-repo>/metadata/*.yml` | one file per package, generated by `scripts/fdroid-metadata.sh` (skeletons come from `fdroid update -c`) |
| `<fdroid-repo>/metadata/<pkg>/en-US/` | per-version changelogs (and an optional icon override), generated from the store's sidecars |
| `<fdroid-repo>/archive/` | APKs `fdroid update` retired from the index |

`fdroid init` writes a large commented template with no identity and no passwords, so
`scripts/fdroid-config.sh` replaces it with the small correct file for this box; re-run
it after changing the `fdroid:` section of `config.yaml`. `scripts/fdroid-sync-apks.sh`
is the one-way store → F-Droid copy (safe to re-run, and it never publishes
`*.test-*.apk` androidTest harnesses).

### Serving the repo — `http://fdroid.bam/repo`

Caddy serves the repo directory straight off the big disk, so nothing has to be
copied anywhere after `scripts/fdroid-publish.sh`:

```
fdroid.bam:80 {
    root * /data/storage/fdroid      # directories.fdroid-repo
    file_server browse
}
```

Add it in an F-Droid client as **`http://fdroid.bam/repo`** (this is the same
value as `fdroid.url` in `config.yaml`, which is baked into the signed index —
change one and re-run `scripts/fdroid-config.sh` + `scripts/fdroid.sh update -c`).

Plain HTTP is deliberate: the box is only reachable over Tailscale, which already
encrypts and authenticates, and the F-Droid index is signed independently of the
transport. As with `apps.bam`, the site is added through the `/data/caddyedit`
API rather than by hand, and the root must also be bind-mounted into the
`/data/caddy-docker` Caddy container or the site 404s.

### The repo signing key (one time, then back it up)

The F-Droid index is signed, so the repo needs its own key before `fdroid init`:

```bash
scripts/fdroid-keystore.sh          # create it — refuses to overwrite an existing one
scripts/fdroid-keystore.sh --show   # path, alias, SHA-256 fingerprint
```

It generates a 4096-bit RSA key (valid ~27 years) into a PKCS#12 keystore at
`directories.fdroid-keystore`, with a random 32-character password written beside it
as `<keystore>.pass` (mode 0600). Both files live on the big disk, outside git, and
`.gitignore` blocks keystores/passwords from ever landing in the repo.

**Back up the keystore and its password file off this box.** If the key is lost the
repo can only be re-signed with a new one, and every client that added it has to
remove and re-add the repo.

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
