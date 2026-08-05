#!/usr/bin/env python3
"""Generate F-Droid per-package metadata from the BAM Store's index.json.

The store already knows every published app (label, versions) and keeps a
changelog sidecar per release; fdroidserver wants the same facts as
``metadata/<package>.yml`` plus ``metadata/<package>/en-US/changelogs/<code>.txt``.
This is a one-way projection (store -> fdroid) and is safe to re-run:

* fields already written in an existing ``<package>.yml`` are **preserved** —
  hand-edit the yml to give an app a real Summary/Description/License and this
  script will never clobber it. Only empty/missing fields get defaults.
* androidTest packages (``*.test``) are skipped, matching fdroid-sync-apks.sh.
* **Icons come from the APK.** ``fdroid update`` extracts and rescales them into
  ``repo/icons-*/`` on its own, so nothing needs to be staged here. The store's
  own aapt2 extraction (which leaves ``icon: null`` for adaptive-icon-only apps)
  is not authoritative; when it *did* produce a file we copy it to
  ``metadata/<pkg>/en-US/icon.png`` as an override for exactly those apps.

Usage (normally via scripts/fdroid-metadata.sh):
    fdroid_metadata.py --store <store-dir> --repo <fdroid-repo-dir> [--author NAME]
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import shutil

DEFAULTS = {
    "License": "Proprietary",
    "Categories": ["BAM"],
}


def load_yml(path: str) -> dict:
    """Parse the tiny flat subset of YAML fdroidserver writes for metadata."""
    data: dict[str, object] = {}
    if not os.path.exists(path):
        return data
    key = None
    with open(path) as f:
        for raw in f:
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if line.startswith("- ") and key:
                data.setdefault(key, [])
                if isinstance(data[key], list):
                    data[key].append(_scalar(line[2:]))
                continue
            if ":" not in line:
                continue
            key, _, value = line.partition(":")
            key = key.strip()
            value = value.strip()
            data[key] = _scalar(value) if value else []
    return data


def _scalar(text: str) -> str:
    text = text.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "'\"":
        return text[1:-1]
    return text


def dump_yml(data: dict) -> str:
    out = []
    for key in sorted(data):
        value = data[key]
        if isinstance(value, list):
            out.append(f"{key}:")
            out.extend(f"- {v}" for v in value)
        elif value == "" or value is None:
            out.append(f"{key}: ''")
        else:
            out.append(f"{key}: {value}")
    return "\n".join(out) + "\n"


def changelogs_for(sidecar_dir: str, package: str) -> dict[int, str]:
    """versionCode -> changelog text, from the store's apks/<pkg>-<code>.json."""
    found: dict[int, str] = {}
    for path in glob.glob(os.path.join(sidecar_dir, f"{package}-*.json")):
        stem = os.path.basename(path)[: -len(".json")]
        code = stem.rsplit("-", 1)[-1]
        if not code.isdigit():
            continue
        with open(path) as f:
            text = (json.load(f) or {}).get("changelog")
        if text:
            found[int(code)] = text
    return found


def write_app(app: dict, args, sidecar_dir: str, icons_dir: str) -> str:
    package = app["packageName"]
    meta_dir = os.path.join(args.repo, "metadata")
    yml_path = os.path.join(meta_dir, f"{package}.yml")

    data = load_yml(yml_path)
    for key, default in DEFAULTS.items():
        if not data.get(key):
            data[key] = list(default) if isinstance(default, list) else default
    if not data.get("Name"):
        data["Name"] = app.get("label") or package
    if not data.get("Summary"):
        data["Summary"] = f"{data['Name']} — built on this box by /data/android/build.sh"
    if not data.get("Description"):
        data["Description"] = data["Summary"]
    # Always tracked, never preserved: it is a projection of the store's latest
    # release, and `fdroid update` only surfaces the changelog whose filename
    # matches CurrentVersionCode (it writes a 2147483647 placeholder otherwise).
    data["CurrentVersionCode"] = app["versionCode"]
    if not data.get("AuthorName") and args.author:
        data["AuthorName"] = args.author

    os.makedirs(meta_dir, exist_ok=True)
    with open(yml_path, "w") as f:
        f.write(dump_yml(data))

    locale_dir = os.path.join(meta_dir, package, "en-US")
    logs = changelogs_for(sidecar_dir, package)
    if logs:
        os.makedirs(os.path.join(locale_dir, "changelogs"), exist_ok=True)
        for code, text in logs.items():
            with open(os.path.join(locale_dir, "changelogs", f"{code}.txt"), "w") as f:
                f.write(text.rstrip("\n") + "\n")

    icon = app.get("icon")
    if icon:
        src = os.path.join(icons_dir, os.path.basename(icon))
        if os.path.isfile(src) and src.endswith(".png"):
            os.makedirs(locale_dir, exist_ok=True)
            shutil.copyfile(src, os.path.join(locale_dir, "icon.png"))

    return f"{package}: {len(logs)} changelog(s)"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--store", required=True, help="BAM Store dir (holds repo/index.json)")
    ap.add_argument("--repo", required=True, help="fdroidserver repo dir (holds metadata/)")
    ap.add_argument("--author", default="", help="AuthorName for apps that lack one")
    args = ap.parse_args()

    index_path = os.path.join(args.store, "repo", "index.json")
    if not os.path.isfile(index_path):
        ap.error(f"no store index at {index_path} — run the publisher first")
    with open(index_path) as f:
        index = json.load(f)

    sidecar_dir = os.path.join(args.store, "repo", "apks")
    icons_dir = os.path.join(args.store, "repo", "icons")

    lines = []
    for app in index.get("apps", []):
        if app["packageName"].endswith(".test"):
            continue
        lines.append(write_app(app, args, sidecar_dir, icons_dir))

    print(f"metadata for {len(lines)} app(s) in {args.repo}/metadata:")
    for line in lines:
        print(f"  {line}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
