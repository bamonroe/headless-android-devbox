# Plan: containerized Android build environment in `/data/android`

Goal: make this directory the single front door for **building** Android APKs, not just
**running** them. Today the emulator half is well-defined; the compile half is fuzzy —
every app project (and every agent working in one) reinvents where the JDK/SDK/Gradle
toolchain lives and how to invoke it. This plan adds a disposable, per-project build
container so no project pollutes the host with SDK/toolchain state.

## Design (agreed)

- **One reusable image** — `android-builder:local`. JDK + Android SDK + Gradle baked in.
  Built once, never re-downloaded. This is the "tools" layer.
- **Ephemeral per-project containers** — spun up per build, run one Gradle build, then
  destroyed (`--rm`). The container is disposable; nothing lingers on the host.
- **Three-mount contract** every Android project follows:
  1. **Project source** → mounted read-write at a fixed path (e.g. `/workspace`).
  2. **Per-project Gradle cache** → mounted at a fixed path the container expects
     (e.g. `/gradle-cache`, wired to `GRADLE_USER_HOME`). Lives **alongside the project**
     (e.g. `<project>/.gradle-cache/` or a sibling dir), so each app's dependencies are
     self-contained and survive the throwaway container. One app's libs never tangle
     with another's; a corrupt cache is one folder to delete.
  3. **APK out** → the build drops the APK where the emulator/phone install step picks
     it up (either read straight from the mounted source tree, or an explicit out dir).
- **This dir owns** the image (`Dockerfile.builder`) and the launch command. App projects
  own nothing but their code + their cache folder + agreement to the mount contract.

## Why the split

- Tools (JDK, SDK, Gradle) differ rarely → bake into the image.
- Per-project dependencies (AndroidX, Compose, Retrofit, …) differ per app/version →
  live in the per-project Gradle cache volume, not the image.
- Container is disposable, but its "brain" (the cache) persists → clean isolation AND
  fast repeat builds.

## Pieces to build

1. **`Dockerfile.builder`** — `eclipse-temurin:21-jdk` base (matches the JDK 21 pinned in
   `~/.gradle/gradle.properties`), install Android cmdline-tools + platform-tools +
   `build-tools;34.x` + `platforms;android-34`, accept licenses, set `ANDROID_SDK_ROOT`
   and `GRADLE_USER_HOME=/gradle-cache`. Consider bootstrapping the big SDK bits onto
   the storage array (reuse it, same as the emulator) vs baking them into the image —
   decide based on how much we want in the image layer.
2. **Launch wrapper / skill command** — e.g. `emulator.sh build <project-dir> [gradle
   task]`, or a new `build.sh`. It: resolves the project dir, ensures the project's cache
   folder exists, runs `docker run --rm -v <proj>:/workspace -v <cache>:/gradle-cache
   android-builder:local ./gradlew <task>`, then prints the resulting APK path.
3. **android-dev skill docs** — document the build container next to the emulator, and the
   three-mount contract, so agents in other projects know to "come here to build."
4. **Per-project CLAUDE.md note** (each app repo) — a one-liner: "build via the
   `/data/android` build container; Gradle cache lives at `<project>/.gradle-cache`."

## Open decisions

- Compose service vs plain `docker run --rm`. Ephemeral one-shot builds favor plain
  `docker run --rm`; docker-compose fits long-lived services (like the emulator) better.
- SDK in image layer vs bootstrapped onto the storage array (shared with the emulator's
  SDK, or a separate build SDK).
- Exact cache location convention: `<project>/.gradle-cache/` (in-tree, git-ignored) vs a
  sibling/central `<project>-cache` dir.
- How the APK crosses from the build container to the emulator/phone install step.
