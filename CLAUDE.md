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

## Start here: the documentation map (hub-and-spoke)

Documentation here is **de-duplicated** — every fact has exactly one authoritative home.
Go to the owner below rather than restating a fact in a second file; link to the owner
instead. Read this table first, then follow only the spoke your task needs.

| You want to know / change…                        | Authoritative home |
|---------------------------------------------------|--------------------|
| **What to do next** (active tasks)                | `TODO.toml` (via the `todo` skill) |
| **What's already done**                           | `FINISHED.toml` (via the `todo` skill) |
| **How to work here** (conventions, decisions)     | `CLAUDE.md` (this file) |
| **How a user runs this** (setup, bring-up, build) | `README.md` |
| **Day-to-day emulator/device/build workflow**     | the `android-dev` skill (`.claude/skills/android-dev`) |
| **The BAM Store** (index contract, client, serving) | `store/CLAUDE.md` |
| **Machine-specific values** (IPs, storage paths)  | `config.yaml` (git-ignored) |
| **Per-app working notes**                         | `NOTES.local.md` (git-ignored) |

Drive `TODO.toml`/`FINISHED.toml` through the `todo` skill (`./scripts/todo.sh <command>`,
see `.claude/skills/todo/SKILL.md`) rather than hand-editing them.

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
- After a successful APK-producing build, `build.sh` publishes each new APK into
  the in-repo BAM Store at `store/` (override with `directories.bam-store` in
  `config.yaml`). The `BAM_STORE_*` / `BUILDER_IMAGE` env knobs that steer this
  are documented in one place — `README.md` → "Environment knobs (build +
  publish)". Don't restate them elsewhere.
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

## The F-Droid repo container (third container here)

Alongside the emulator and the builder there is now an **fdroidserver toolbox**:
`Dockerfile.fdroid` (tag `fdroid:local`), built `FROM android-builder:local` so the
JDK + SDK (`aapt2`, `apksigner`, `zipalign`) are reused rather than duplicated. It
owns index generation and signing for the F-Droid-style APK repo.

- The repo dir itself (`directories.fdroid-repo`) is **entirely off git** — config,
  APKs, metadata and the signed index are all regenerable. `scripts/fdroid-config.sh`
  regenerates its `config.yml` from `config.yaml`, and `scripts/fdroid-sync-apks.sh`
  copies the store's binaries into `repo/` (skipping androidTest APKs). Layout table:
  `README.md` → "The repo layout, and what's committed".
- **`scripts/fdroid-publish.sh`** is the composite step (sync APKs → project
  metadata → `fdroid update -c`), and `build.sh` runs it after every successful
  BAM Store publish so both indexes stay in sync; `FDROID_PUBLISH=0` opts out.
  Metadata generation itself lives in `scripts/fdroid_metadata.py` (yml merge
  rules, changelogs, the icons-come-from-the-APK decision) behind the
  `scripts/fdroid-metadata.sh` path wrapper.
- Drive it with **`scripts/fdroid.sh`** (`init`, `update -c`, `deploy`, `shell`) —
  never with a hand-typed `docker run`. It mounts `directories.fdroid-repo` at
  `/repo` and `directories.fdroid-keystore` read-only at `/keystore`, and runs as the
  invoking uid so nothing comes back root-owned.
- Repo identity (`url`, `name`, `description`, `keystore-alias`) lives in the
  `fdroid:` section of `config.yaml`. The keystore is **never** in git.
- The signing key is created once by **`scripts/fdroid-keystore.sh`** (PKCS#12 +
  a `<keystore>.pass` sidecar on the big disk, both 0600). It refuses to
  overwrite an existing keystore — re-signing with a new key breaks every client
  that added the repo. User-facing details: `README.md` → "The repo signing key".
- It is also a compose service behind the `tools` profile, so a bare
  `docker compose up` never starts it.
- Rebuild after editing the Dockerfile:
  `docker build -f Dockerfile.fdroid -t fdroid:local .`
- User-facing commands + env knobs: `README.md` → "F-Droid repo toolbox".

## Publishing to the app store

Publishing is automatic for APKs produced by `/data/android/build.sh`: after Gradle
finishes successfully, the script finds APKs written under `build/outputs/apk/` during
that build and runs the BAM Store publisher for each one. The store is `store/` in
this repo; `directories.bam-store` in `config.yaml` is an optional override.

What `build.sh` owns here: it publishes only APKs written during *that* build, one
publisher run per APK, and then re-syncs the F-Droid index via
`scripts/fdroid-publish.sh` — a failure there warns but doesn't fail the build
(`FDROID_PUBLISH=0` opts out). Env knobs: `README.md` → "Environment knobs (build +
publish)".

Everything else about the store — the `repo/index.json` contract, what's committed
versus generated, the `com.bam.store` client, manual `tools/publish` / `tools/reindex`
use, and serving — lives in **`store/CLAUDE.md`**. Go there rather than restating it.

## Storage layout

`<storage>` = `directories.storage` in `config.yaml` (a big disk, not the system disk).

| Path | What | Where |
|---|---|---|
| `<storage>/android/sdk` | cmdline-tools, platform-tools, emulator, system images | big disk |
| `<storage>/android/avd` | AVD config + qcow2 disks | big disk |
| `directories.bam-store-apks` | the store's APK binaries (hundreds of MB) | big disk |
| `directories.fdroid-repo` | fdroidserver repo dir (`repo/`, `metadata/`, signed index) | big disk |
| `directories.fdroid-keystore` | the F-Droid repo **signing key** — never in git, back it up | big disk |
| `store/repo/` | `index.json`, icons, changelog sidecars — the small, committed parts | this repo |
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

See also `README.md` here (user-facing version), the `android-dev` skill, the in-repo
app store (`store/`), and the memory notes
`android-emulator-setup` / `android-emulator-and-phone-adb`.

---

## Development style guide — technology defaults (standing preferences)

Standing defaults for *how* things get built. They apply to every project; deviate only
with a concrete written reason recorded here.

### Develop inside containers — Docker first, then Podman

Do development, builds, and runs **inside containers**, not against the host toolchain — a
fresh checkout should build and run through a container so the environment is reproducible
and the host stays clean. This repo already embodies that: the emulator and the APK builder
are both containers, and no JDK/SDK/Gradle is installed on the host.

- **Prefer Docker** — write `Dockerfile`/`docker-compose.yml` for Docker and assume
  `docker`/`docker compose` in scripts and docs.
- **Fall back to Podman** where Docker isn't available; keep the setup Podman-compatible
  (rootless-friendly, no Docker-only Compose features) and note command differences.
- Note the one deliberate host dependency: `/dev/kvm` and the host's `/usr/bin/adb` for
  physical devices (see the two-adb-worlds section above).

### Web servers are written in Rust

If anything here ever needs an HTTP/web-server component, write it in Rust with a mature
async stack (`axum`/`tokio` or `actix-web`). Another language only with a reason recorded here.

### Keep the code split up — no mono-files, no giant functions

- **No single mono-file** and no mono-module — split along real boundaries, one clear
  responsibility per file. That applies to the shell scripts here too: `config.sh`,
  `build.sh`, `entrypoint.sh` and the skill's scripts stay separate and focused.
- **Keep functions small — roughly 100 lines max.** Past that, extract helpers.
- The point is navigation, documentation, and testing: a reader should find the right file
  by its name, and each unit should be small enough to test in isolation.

---

## Working practices (standing preferences)

### Git: commit atomically, at will and frequently — and push freely

You have standing authorization to commit **and push** your own work without asking first.
Never let work pile up uncommitted.

- **Atomic commits**: one logical change each — a fix, a feature, a doc update, and a
  refactor are separate commits. Commit the smallest coherent unit that builds clean.
- Make the change → verify it → **commit**. Many small commits beat one large one; history
  stays bisectable and revertable.
- Concise **imperative** subject saying *why*, not just *what*.
- **Commit before risky or large changes**; branch for anything speculative so `master`
  stays runnable.
- **Push freely** after committing — keeping the remote current is part of "done."
- Never commit secrets, databases, or build artifacts. Here specifically: `config.yaml` and
  `NOTES.local.md` are git-ignored and must stay that way.

### A feature isn't done until it's documented

Documentation is part of the feature, not a follow-up.

- Every user-facing change gets documentation in `README.md` in the same pass; conventions
  and how-it-fits go here; workflow details go in the `android-dev` skill.
- Docs land in the **same commit** as the change (or immediately after).
- Any script or command needed to build, run, publish, or operate this setup **must be
  written down** — put reusable steps in a checked-in script and reference it from both
  `README.md` and this file. Nothing load-bearing lives only in shell history.

### `TODO.toml` (active) + `FINISHED.toml` (archive) — keep them current

When task tracking starts here, `TODO.toml` is the single source of truth for **active**
work and `FINISHED.toml` the archive of **completed** work. Both are TOML with structured
metadata (`id`, `status`, `level`, `category`, `urgency`, `order`, `created`/`completed`, `tags`).
**Drive them through the `todo` skill** (`scripts/todo.sh <command>`) rather than
hand-editing, so ids, ordering, and metadata stay consistent.

- Update them in the same commit as the work they describe.
- When a task is fully finished (built, tested, documented), `scripts/todo.sh done <id>`
  moves it into `FINISHED.toml`. Don't leave completed items in `TODO.toml`.
- Journal next steps: when you finish something and spot the next piece, `add` it.
- A stale `TODO.toml`/`FINISHED.toml` means the change isn't done.

### Token discipline — keep the context small

- **Read in slices, not whole files** — `grep`/`glob` to the target, then `Read` with
  `offset`/`limit`. Never re-read a file you just edited.
- **Delegate broad searches to `Explore` subagents** so file dumps stay out of this context.
- **Don't restate; link** to the owning doc per the map above.
- **Prefer targeted output** — pipe long output through `head`/`tail`/`grep`; don't cat
  whole logs or list huge trees.
