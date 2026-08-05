"""Shared helpers for the BAM Store repository tooling.

The repository is a plain directory of APKs plus a generated ``index.json``:

    repo/
      apks/   <package>-<versionCode>.apk   + <package>-<versionCode>.json sidecar
      icons/  <package>.<ext>
      index.json

The APK binaries are the one part that must **not** sit on the system disk (they
run to hundreds of MB), so ``BAM_STORE_APKS`` may point them at a big disk while
the tiny committed changelog sidecars stay in ``repo/apks/`` inside git. When it
is unset both live together and the layout above is literal. Either way the
``apk`` field in the index stays the repo-relative ``apks/<file>`` the client
expects, so the split is invisible over HTTP as long as the server maps
``/apks/`` at the same directory (see repo/Caddyfile.example).

Metadata is read straight out of each APK with ``aapt2 dump badging`` so the
index is always fully regenerable from the APK files on disk (see reindex).
"""

from __future__ import annotations

import glob
import hashlib
import json
import os
import re
import subprocess
import zipfile
from dataclasses import dataclass, asdict

REPO_DIR = os.environ.get(
    "BAM_STORE_REPO",
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "repo"),
)
SIDECARS_DIR = os.path.join(REPO_DIR, "apks")
APKS_DIR = os.environ.get("BAM_STORE_APKS") or SIDECARS_DIR
ICONS_DIR = os.path.join(REPO_DIR, "icons")
INDEX_PATH = os.path.join(REPO_DIR, "index.json")
SDK_DIR = os.environ.get("ANDROID_HOME") or os.path.expanduser("~/Android/Sdk")


def find_aapt2() -> str:
    """Return the newest aapt2 from the SDK's build-tools, or error out."""
    candidates = sorted(glob.glob(os.path.join(SDK_DIR, "build-tools", "*", "aapt2")))
    if not candidates:
        raise SystemExit(
            f"aapt2 not found under {SDK_DIR}/build-tools. "
            "Set ANDROID_HOME or install build-tools."
        )
    return candidates[-1]


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


@dataclass
class AppMeta:
    packageName: str
    label: str
    versionName: str
    versionCode: int
    minSdk: int
    size: int
    sha256: str
    apk: str          # repo-relative path
    icon: str | None  # repo-relative path
    changelog: str | None


def _badging(apk: str) -> dict:
    out = subprocess.run(
        [find_aapt2(), "dump", "badging", apk],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        raise SystemExit(f"aapt2 failed on {apk}:\n{out.stderr}")
    text = out.stdout

    pkg = re.search(r"package: name='([^']+)' versionCode='([^']*)' versionName='([^']*)'", text)
    if not pkg:
        raise SystemExit(f"could not parse package line for {apk}")
    label = re.search(r"application-label:'([^']*)'", text)
    min_sdk = re.search(r"minSdkVersion:'([0-9]+)'", text)

    # Prefer the highest-density raster icon; skip adaptive-icon XML entries.
    icons = re.findall(r"application-icon-(\d+):'([^']+)'", text)
    icon_path = None
    for _, path in sorted(icons, key=lambda t: int(t[0])):
        if not path.endswith(".xml"):
            icon_path = path
    if icon_path is None:
        generic = re.search(r"application:.*icon='([^']+)'", text)
        if generic and not generic.group(1).endswith(".xml"):
            icon_path = generic.group(1)

    return {
        "packageName": pkg.group(1),
        "versionCode": int(pkg.group(2) or 0),
        "versionName": pkg.group(3) or "?",
        "label": label.group(1) if label else pkg.group(1),
        "minSdk": int(min_sdk.group(1)) if min_sdk else 0,
        "iconEntry": icon_path,
    }


def _extract_icon(apk: str, package: str, icon_entry: str | None) -> str | None:
    if not icon_entry:
        return None
    os.makedirs(ICONS_DIR, exist_ok=True)
    ext = os.path.splitext(icon_entry)[1] or ".png"
    dest = os.path.join(ICONS_DIR, f"{package}{ext}")
    try:
        with zipfile.ZipFile(apk) as z:
            data = z.read(icon_entry)
    except KeyError:
        return None
    with open(dest, "wb") as f:
        f.write(data)
    return os.path.relpath(dest, REPO_DIR)


def meta_for_apk(apk: str, changelog: str | None) -> AppMeta:
    b = _badging(apk)
    icon = _extract_icon(apk, b["packageName"], b["iconEntry"])
    return AppMeta(
        packageName=b["packageName"],
        label=b["label"],
        versionName=b["versionName"],
        versionCode=b["versionCode"],
        minSdk=b["minSdk"],
        size=os.path.getsize(apk),
        sha256=sha256(apk),
        apk=f"apks/{os.path.basename(apk)}",
        icon=icon,
        changelog=changelog,
    )


def sidecar_path(apk: str) -> str:
    """Where an APK's changelog sidecar lives — beside it, or in the git dir."""
    name = os.path.splitext(os.path.basename(apk))[0] + ".json"
    return os.path.join(SIDECARS_DIR, name)


def write_index(apps: list[AppMeta], name: str = "BAM Store") -> None:
    payload = {
        "repo": {"name": name},
        "apps": [asdict(a) for a in sorted(apps, key=lambda a: a.label.lower())],
    }
    with open(INDEX_PATH, "w") as f:
        json.dump(payload, f, indent=2)
        f.write("\n")


def rebuild_index() -> list[AppMeta]:
    """Rescan apks/, keep the highest versionCode per package, write index.json."""
    latest: dict[str, AppMeta] = {}
    for apk in sorted(glob.glob(os.path.join(APKS_DIR, "*.apk"))):
        changelog = None
        sc = sidecar_path(apk)
        if os.path.exists(sc):
            with open(sc) as f:
                changelog = json.load(f).get("changelog")
        m = meta_for_apk(apk, changelog)
        cur = latest.get(m.packageName)
        if cur is None or m.versionCode >= cur.versionCode:
            latest[m.packageName] = m
    apps = list(latest.values())
    write_index(apps)
    return apps
