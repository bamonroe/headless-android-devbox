"""Run ``aapt2 dump badging`` without requiring a host Android SDK.

Per /data/android/CLAUDE.md the host carries no JDK/SDK/Gradle: the toolchain
lives in the ``android-builder:local`` image. So metadata extraction runs there
by default — a throwaway container with the APK's directory bind-mounted
read-only — and only falls back to a host ``aapt2`` when one happens to exist.

Knobs:
  BAM_STORE_AAPT2        — an explicit aapt2 binary; used directly, no container.
  BAM_STORE_BUILDER_IMAGE / BUILDER_IMAGE — builder image (default android-builder:local).
  ANDROID_HOME           — host SDK root for the fallback (default ~/Android/Sdk).
"""

import glob
import os
import shutil
import subprocess

IMAGE = (
    os.environ.get("BAM_STORE_BUILDER_IMAGE")
    or os.environ.get("BUILDER_IMAGE")
    or "android-builder:local"
)
SDK_DIR = os.environ.get("ANDROID_HOME") or os.path.expanduser("~/Android/Sdk")

# Glob inside the image; the baked SDK root is /opt/android-sdk.
_IN_IMAGE_SCRIPT = (
    'set -e; a=$(ls -1 "$ANDROID_SDK_ROOT"/build-tools/*/aapt2 | sort | tail -1); '
    'exec "$a" dump badging /apk/"$1"'
)


def find_host_aapt2() -> str | None:
    """Newest aapt2 from a host SDK's build-tools, or one on PATH — if any."""
    explicit = os.environ.get("BAM_STORE_AAPT2")
    if explicit:
        return explicit
    candidates = sorted(glob.glob(os.path.join(SDK_DIR, "build-tools", "*", "aapt2")))
    if candidates:
        return candidates[-1]
    return shutil.which("aapt2")


def _dump_in_container(apk: str) -> subprocess.CompletedProcess:
    apk = os.path.abspath(apk)
    return subprocess.run(
        [
            "docker", "run", "--rm",
            "-v", f"{os.path.dirname(apk)}:/apk:ro",
            "--entrypoint", "sh",
            IMAGE, "-c", _IN_IMAGE_SCRIPT, "aapt2", os.path.basename(apk),
        ],
        capture_output=True, text=True,
    )


def dump_badging(apk: str) -> str:
    """Return ``aapt2 dump badging`` output for an APK, container-first."""
    explicit = os.environ.get("BAM_STORE_AAPT2")
    if explicit:
        return _run([explicit, "dump", "badging", apk], apk)

    if shutil.which("docker"):
        out = _dump_in_container(apk)
        if out.returncode == 0:
            return out.stdout
        container_err = out.stderr.strip()
    else:
        container_err = "docker not found on PATH"

    host = find_host_aapt2()
    if host:
        return _run([host, "dump", "badging", apk], apk)

    raise SystemExit(
        f"could not read {apk}: aapt2 unavailable.\n"
        f"  container ({IMAGE}): {container_err}\n"
        f"  host: no aapt2 under {SDK_DIR}/build-tools or on PATH.\n"
        "Build the image with: docker build -f Dockerfile.builder "
        "-t android-builder:local /data/android"
    )


def _run(cmd: list[str], apk: str) -> str:
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit(f"aapt2 failed on {apk}:\n{out.stderr}")
    return out.stdout
