#!/usr/bin/env python3
"""Xcode embed phase: require verified runtime, sign libraries and record bytes."""
import json
import os
import shutil
import subprocess
from pathlib import Path

from build_analysis_runtime import verify
from prepare_native import digest


def main():
    source = verify("macos-arm64")
    frameworks = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["FRAMEWORKS_FOLDER_PATH"]
    resources = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["UNLOCALIZED_RESOURCES_FOLDER_PATH"] / "LiveSync"
    frameworks.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    record = json.loads((source / "provenance.json").read_text())
    bundled = {}
    for name in record["files"]:
        target = (frameworks if name.endswith(".dylib") else resources) / name
        shutil.copyfile(source / name, target)
        if name.endswith(".dylib"):
            identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
            subprocess.run(["codesign", "--force", "--sign", identity, str(target)], check=True)
        bundled[name] = digest(target)
    (resources / "analysis-runtime.json").write_text(json.dumps({"source": record, "bundledSha256": bundled}, indent=2) + "\n")


if __name__ == "__main__":
    main()
