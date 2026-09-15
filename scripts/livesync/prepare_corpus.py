#!/usr/bin/env python3
"""Fetch only reviewed redistributable test sources; never process user media.

Preserves source bytes and attribution notices. Does not transcribe or analyze
the held-out partitions, and does not establish acoustic ground-truth anchors.
"""

import argparse
import json
import os
from pathlib import Path
import tempfile
import time
import urllib.request

from prepare_native import ROOT, digest


def fetch(entry, directory):
    target = directory / entry["name"]
    if target.name != entry["name"] or not entry["url"].startswith("https://media.xiph.org/"):
        raise ValueError("Unexpected corpus source descriptor")
    if target.exists():
        if target.stat().st_size != entry["bytes"] or digest(target) != entry["sha256"]:
            raise ValueError("Existing corpus source differs; preserving it for inspection")
        return
    temporary = None
    try:
        deadline = time.monotonic() + 600
        with tempfile.NamedTemporaryFile(prefix=".livesync-corpus-", dir=directory, delete=False) as output:
            temporary = Path(output.name)
            with urllib.request.urlopen(entry["url"], timeout=30) as response:
                size = 0
                while chunk := response.read(1024 * 1024):
                    size += len(chunk)
                    if size > entry["bytes"] or time.monotonic() > deadline:
                        raise ValueError("Corpus download exceeded its size or time bound")
                    output.write(chunk)
        if temporary.stat().st_size != entry["bytes"] or digest(temporary) != entry["sha256"]:
            raise ValueError("Corpus source checksum mismatch")
        # Both files are on the same filesystem. Link fails atomically if a
        # concurrent task created the destination; never replace that file.
        os.link(temporary, target)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads((ROOT / "test/fixtures/livesync/corpus-sources.json").read_text())
    args.output.mkdir(parents=True, exist_ok=True)
    for source in manifest["sources"]:
        for entry in source["files"]:
            fetch(entry, args.output)
        print(f"Verified {source['id']}: {source['license']}; source bytes unchanged, no inference performed")


if __name__ == "__main__":
    main()
