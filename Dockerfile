# Headless Android emulator for driving on-device tests over adb.
#
# The image stays tiny: just a JDK + the libs the emulator binary links against.
# Everything large (cmdline-tools, platform-tools, the emulator, system images,
# and the AVD's qcow2 disks) is bootstrapped at runtime into bind-mounted dirs on
# the /data/storage HDD array — see docker-compose.yml. Nothing multi-GB ever
# lands on the system disk or in an image layer.
FROM eclipse-temurin:17-jdk-jammy

ENV ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_AVD_HOME=/data/avd \
    PATH=/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/emulator:/usr/lib/jvm/temurin-17-jdk-amd64/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Runtime deps for the QEMU-based emulator + swiftshader software GL.
RUN apt-get update && apt-get install -y --no-install-recommends \
        unzip curl ca-certificates \
        libpulse0 libgl1 libnss3 libxcomposite1 libxcursor1 libxi6 \
        libxtst6 libasound2 libx11-6 libxrandr2 libxdamage1 \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
