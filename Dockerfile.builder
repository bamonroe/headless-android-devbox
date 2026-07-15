# Disposable Android BUILD environment (sibling to the emulator image here).
#
# This image is the "tools" layer: JDK 21 (matches the JDK pinned in
# ~/.gradle/gradle.properties) + the Android SDK, all baked in so nothing large is
# downloaded per build and no two build containers can collide over a shared SDK.
#
# It is meant to be run DISPOSABLY, one throwaway container per build:
#
#   docker run --rm \
#     -v <project-parent>:/workspace \
#     -v <project-gradle-cache>:/gradle-cache \
#     -w /workspace/<project-dir-name> \
#     android-builder:local ./gradlew :app:assembleDebug
#
# The mount contract:
#   /workspace     <- the app project's parent dir. This keeps sibling repo inputs
#                     such as ../docs visible to Gradle while APKs still land under
#                     the project build/ dir.
#   /gradle-cache  <- the project's OWN persistent Gradle cache (GRADLE_USER_HOME)
# The SDK is NOT a mount — it is baked into the image, private to each container.
#
# Each project's Gradle wrapper (gradlew) downloads its own Gradle version into the
# mounted /gradle-cache, so this image does not pin a Gradle version. build.sh also
# sets HOME=/gradle-cache so Android's default debug keystore is stable per project.
FROM eclipse-temurin:21-jdk-jammy

ENV ANDROID_SDK_ROOT=/opt/android-sdk \
    GRADLE_USER_HOME=/gradle-cache \
    PATH=/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# git is handy for Gradle plugins that read VCS info; the rest are curl/unzip to
# bootstrap the SDK at build time.
RUN apt-get update && apt-get install -y --no-install-recommends \
        unzip curl ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

# 1) cmdline-tools -> /opt/android-sdk/cmdline-tools/latest
RUN set -eux; \
    curl -fsSL -o /tmp/cmdtools.zip \
      https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip; \
    mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools"; \
    unzip -q /tmp/cmdtools.zip -d "$ANDROID_SDK_ROOT/cmdline-tools"; \
    mv "$ANDROID_SDK_ROOT/cmdline-tools/cmdline-tools" "$ANDROID_SDK_ROOT/cmdline-tools/latest"; \
    rm -f /tmp/cmdtools.zip

# 2) Accept licenses, then bake in platform-tools + the SDK platforms/build-tools the
#    apps on this box compile against (currently compileSdk 34 and 35).
#    Add more platforms;android-NN / build-tools;NN.x lines here as new apps appear.
RUN set -eux; \
    yes | sdkmanager --licenses >/dev/null; \
    sdkmanager --install \
      "platform-tools" \
      "platforms;android-34" "build-tools;34.0.0" \
      "platforms;android-35" "build-tools;35.0.0" \
      >/dev/null

# Non-root build user so files written into the mounted project keep sane ownership.
# (Override at run time with `--user "$(id -u):$(id -g)"` to match the host caller.)
WORKDIR /workspace
CMD ["bash"]
