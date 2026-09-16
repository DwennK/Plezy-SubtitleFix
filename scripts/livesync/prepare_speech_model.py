#!/usr/bin/env python3
"""Download the pinned speech detector independently of mpv build preparation."""

import argparse
import json
from pathlib import Path

from prepare_native import MANIFEST, download_model


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dest", type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text())
    print(download_model(manifest["speechDetector"], args.dest))


if __name__ == "__main__":
    main()
