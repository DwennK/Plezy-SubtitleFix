#!/usr/bin/env python3
"""Prepare exactly the reviewed native sources; never follow branch tips."""

import argparse
import hashlib
import json
import shutil
import subprocess
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "docs/live-subtitle-sync-versions.json"


def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def checkout(url, revision, destination):
    destination = Path(destination).resolve()
    if not destination.exists():
        destination.mkdir(parents=True)
        run("git", "init", str(destination))
        run("git", "-C", str(destination), "remote", "add", "origin", url)
        run("git", "-C", str(destination), "fetch", "--depth", "1", "origin", revision)
        run("git", "-C", str(destination), "checkout", "--detach", "FETCH_HEAD")
    actual = run("git", "-C", str(destination), "rev-parse", "HEAD")
    if actual != revision:
        raise RuntimeError(f"Refusing existing checkout at {actual}; expected {revision}")
    return destination


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def download_model(model, destination):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    target = destination / model["file"]
    if target.exists() and target.stat().st_size == model["bytes"] and digest(target) == model["sha256"]:
        return target
    temporary = target.with_suffix(".partial")
    try:
        with urllib.request.urlopen(model["url"], timeout=60) as response, temporary.open("wb") as output:
            size = 0
            while chunk := response.read(1024 * 1024):
                size += len(chunk)
                if size > model["bytes"]:
                    raise ValueError("Model exceeds its pinned size")
                output.write(chunk)
        if size != model["bytes"] or digest(temporary) != model["sha256"]:
            raise ValueError("Model checksum or size mismatch")
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    return target


def prepare_mpv(manifest, destination):
    native = manifest["native"]
    patch = ROOT / "native/live_subtitle_sync/patches/0001-bounded-timestamped-pcm-tap.patch"
    if digest(patch) != native["liveSyncPatchSha256"]:
        raise ValueError("LiveSync patch differs from the reviewed manifest")
    dest = checkout("https://github.com/" + native["repo"], native["commit"], destination)
    compatibility = ROOT / "native/live_subtitle_sync/patches/0002-windows-curl-scp-header.patch"
    if digest(compatibility) != native["windowsCompatibilityPatchSha256"]:
        raise ValueError("Windows compatibility patch differs from the reviewed manifest")
    applicable = subprocess.run(["git", "apply", "--check", str(compatibility)], cwd=dest, capture_output=True)
    if applicable.returncode == 0:
        run("git", "apply", str(compatibility), cwd=dest)
    else:
        # Repeated preparation is allowed only if this exact patch is present.
        run("git", "apply", "--reverse", "--check", str(compatibility), cwd=dest)
    name = "0900-livesync-pcm-tap.patch"
    shutil.copyfile(patch, dest / "patches/mpv/pool" / name)
    for platform in ("apple", "windows"):
        series = dest / "patches/mpv" / ("series." + platform)
        content = series.read_text()
        if name not in content.splitlines():
            series.write_text(content.rstrip() + "\n" + name + "\n")
    import sys
    run(sys.executable, "scripts/patches.py", "check", cwd=dest)
    return dest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("component", choices=("whisper", "mpv-build", "models", "speech-model"))
    parser.add_argument("--dest", type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text())
    if args.component == "models":
        for model in manifest["models"]:
            print(download_model(model, args.dest))
    elif args.component == "speech-model":
        print(download_model(manifest["speechDetector"], args.dest))
    elif args.component == "mpv-build":
        print(prepare_mpv(manifest, args.dest))
    else:
        whisper = manifest["whisper"]
        print(checkout(whisper["repository"], whisper["revision"], args.dest))


if __name__ == "__main__":
    main()
