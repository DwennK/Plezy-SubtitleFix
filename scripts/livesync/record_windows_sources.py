#!/usr/bin/env python3
"""Record actual fetched Windows dependency revisions, including upstream floating refs."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    directory = args.native / "build/windows/src"
    revisions = {}
    candidates = list(directory.iterdir()) if directory.is_dir() else []
    candidates.append(args.native / "build/windows/mpv-winbuild-cmake")
    for source in sorted(candidates):
        if not (source / ".git").exists():
            continue
        head = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
        patch = subprocess.check_output(["git", "-C", str(source), "diff", "--binary", "HEAD"])
        revisions[source.name] = {"revision": head, "trackedDiffSha256": hashlib.sha256(patch).hexdigest()}
    report = {"recordedAt": datetime.now(timezone.utc).isoformat(), "sourceRevisions": revisions,
              "scope": "observed fetched sources; some transitive recipes in upstream winbuild use floating refs",
              "completeReproducibilityValidated": False}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
