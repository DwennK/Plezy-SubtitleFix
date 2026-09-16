#!/usr/bin/env python3
"""Prepare only the pinned Sintel calibration partition for the native player.

The six-channel variant places real dialogue in the center channel and silence
in the others. It tests the analysis path, not a genuine surround film mix.
"""
import argparse
import json
import shutil
import subprocess
from pathlib import Path

from prepare_corpus import fetch
from prepare_native import ROOT, digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--channels", type=int, choices=[2, 6], default=2)
    args = parser.parse_args()
    manifest = json.loads((ROOT / "test/fixtures/livesync/corpus-sources.json").read_text())
    source = next(entry for entry in manifest["sources"] if entry["id"] == "sintel-stereo-en")
    args.source.mkdir(parents=True, exist_ok=True)
    args.output.mkdir(parents=True, exist_ok=True)
    for entry in source["files"]:
        fetch(entry, args.source)
    command = ["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "color=c=0x10151e:s=1280x720:r=24:d=75",
               "-ss", "100", "-t", "75", "-i", str(args.source / "sintel-master-st.flac"),
               "-map", "0:v", "-map", "1:a"]
    if args.channels == 6:
        command += ["-af", "pan=5.1|FL=0*c0|FR=0*c0|FC=0.5*c0+0.5*c1|LFE=0*c0|BL=0*c0|BR=0*c0"]
    command += ["-c:v", "ffv1", "-c:a", "pcm_s16le", "-metadata:s:a:0", "language=eng",
                "-t", "75", str(args.output / "fixture.mkv")]
    subprocess.run(command, check=True)
    shutil.copyfile(args.source / "sintel_en.srt", args.output / "fixture.srt")
    shutil.copyfile(args.model, args.output / "model.bin")  # Player verifies pinned size and SHA before use.
    record = {"source": source["id"], "attribution": source["attribution"], "license": source["license"],
              "partition": [100, 175], "role": "calibration", "expectedOffsetSeconds": -100,
              "channels": args.channels, "syntheticChannelRouting": args.channels == 6,
              "files": {name: digest(args.output / name) for name in ["fixture.mkv", "fixture.srt"]}}
    (args.output / "fixture-provenance.json").write_text(json.dumps(record, indent=2) + "\n")


if __name__ == "__main__":
    main()
